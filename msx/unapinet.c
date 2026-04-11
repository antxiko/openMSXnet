// ============================================================
//  UNAPINET.C  –  TSR UNAPI TCPIP para Nextor / MSX-DOS 2
//  Phase 2: DNS + TCP completo
//
//  Build: msxGL (SDCC), target MSX-DOS → genera UNAPINET.COM
// ============================================================

#include "msxgl.h"

// ============================================================
//  Puertos del bridge (acceso directo via __sfr)
// ============================================================
__sfr __at(0x7E) PORT_CMD;   // W=comando  R=status
__sfr __at(0x7F) PORT_DATA;  // W=param    R=dato

// ============================================================
//  Constantes del protocolo bridge
// ============================================================

// Comandos bridge → extensión openMSX
#define CMD_PING        0x00
#define CMD_DNS_QUERY   0x01
#define CMD_DNS_STATUS  0x02
#define CMD_TCP_OPEN    0x03
#define CMD_TCP_SEND    0x04
#define CMD_TCP_RECV    0x05
#define CMD_TCP_CLOSE   0x06
#define CMD_TCP_STATE   0x07
#define CMD_TCP_ABORT   0x08
#define CMD_GET_LOCALIP 0x0D
#define CMD_NET_STATE   0x0E
#define CMD_QUERY_CAP   0x10

// Status del bridge
#define STATUS_OK    0x00
#define STATUS_ERROR 0x01
#define STATUS_DATA  0x02
#define PING_MAGIC   0xAB

// ============================================================
//  UNAPI error codes (spec Konamiman)
// ============================================================
#define ERR_OK            0
#define ERR_NOT_IMP       1
#define ERR_NO_NETWORK    2
#define ERR_NO_DATA       3
#define ERR_INV_PARAM     4
#define ERR_QUERY_EXISTS  5
#define ERR_INV_IP        6
#define ERR_NO_DNS        7
#define ERR_DNS           8
#define ERR_NO_FREE_CONN  9
#define ERR_CONN_EXISTS   10
#define ERR_NO_CONN       11
#define ERR_CONN_STATE    12
#define ERR_BUFFER        13
#define ERR_LARGE_DGRAM   14
#define ERR_INV_OPER      15

// UNAPI signature y versión
#define UNAPI_ID          "TCPIP"
#define UNAPI_VER_MAIN    1
#define UNAPI_VER_SEC     1

// Hook EXTBIO
#define EXTBIO_HOOK       0xFFCA

// Capabilities flags (TCPIP_GET_CAPAB block 1)
// Bit 2: DNS querying, Bit 3: TCP active mode
#define CAPS_FLAGS   0x000C
// Features flags = mismas que capabilities (todas activas)
#define FEAT_FLAGS   0x000C

// Máximo conexiones TCP
#define MAX_TCP      4

// ============================================================
//  Helpers de consola
// ============================================================

static void dos_putchar(u8 c) __naked
{
    (void)c;
    __asm
        ld      e, a            ; SDCC pasa u8 en A
        ld      c, #0x02        ; BDOS función 2: console output
        call    #0x0005
        ret
    __endasm;
}

static void dos_print(const char* s)
{
    while (*s) {
        dos_putchar((u8)*s);
        s++;
    }
}

// ============================================================
//  Helpers del bridge
// ============================================================

static inline void bridge_cmd(u8 cmd)
{
    PORT_CMD = cmd;
}

static inline u8 bridge_status(void)
{
    return PORT_CMD;
}

static inline u8 bridge_read(void)
{
    return PORT_DATA;
}

static inline void bridge_write(u8 val)
{
    PORT_DATA = val;
}

// Lee N bytes del bridge tras STATUS_DATA
static bool bridge_read_bytes(u8* buf, u8 count)
{
    if (bridge_status() != STATUS_DATA) return FALSE;
    for (u8 i = 0; i < count; i++) {
        buf[i] = bridge_read();
    }
    return TRUE;
}

// ============================================================
//  Detección de la extensión openMSX
// ============================================================

static bool detect_extension(void)
{
    bridge_cmd(CMD_PING);
    if (bridge_status() != STATUS_DATA) return FALSE;
    return (bridge_read() == PING_MAGIC);
}

// ============================================================
//  Estado local de conexiones TCP
//  (para poder responder TCPIP_GET_CAPAB block 2 sin
//   consultar el bridge por cada handle)
// ============================================================

static u8 tcp_active[MAX_TCP]; // 0=free, 1=active

static u8 count_free_tcp(void)
{
    u8 count = 0;
    for (u8 i = 0; i < MAX_TCP; i++) {
        if (!tcp_active[i]) count++;
    }
    return count;
}

// ============================================================
//  Registros de intercambio ASM ↔ C
//
//  El dispatcher (naked asm) guarda los registros de entrada
//  aquí antes de llamar a dispatch_unapi().
//  Las funciones C escriben los de salida.
// ============================================================

static u8 reg_a, reg_b, reg_c, reg_d, reg_e, reg_h, reg_l;

// ============================================================
//  Funciones UNAPI TCPIP  (llamadas desde dispatch_unapi)
// ============================================================

// --- Función 0: UNAPI_GET_INFO ---
// Salida: HL = puntero a firma, B = ver_main, C = ver_sec
static void fn_get_info(void)
{
    // HL apunta a la firma dentro del bloque UNAPI (+3 bytes)
    reg_h = 0x80; // high byte de 0x8003
    reg_l = 0x03; // low  byte de 0x8003
    reg_b = UNAPI_VER_MAIN;
    reg_c = UNAPI_VER_SEC;
    reg_a = ERR_OK;
}

// --- Función 1: TCPIP_GET_CAPAB ---
// Entrada: B = bloque (1-4)
static void fn_get_capab(void)
{
    switch (reg_b) {
    case 1: // Capabilities y features flags
        reg_l = (u8)(CAPS_FLAGS & 0xFF);
        reg_h = (u8)((CAPS_FLAGS >> 8) & 0xFF);
        reg_e = (u8)(FEAT_FLAGS & 0xFF);
        reg_d = (u8)((FEAT_FLAGS >> 8) & 0xFF);
        reg_b = 0; // link level protocol: unknown
        reg_a = ERR_OK;
        break;

    case 2: // Connection pool sizes
        reg_b = MAX_TCP;           // max TCP
        reg_c = 0;                 // max UDP (Phase 3)
        reg_d = count_free_tcp();  // free TCP
        reg_e = 0;                 // free UDP
        reg_h = 0;                 // max raw
        reg_l = 0;                 // free raw
        reg_a = ERR_OK;
        break;

    case 3: // Datagram sizes
        // max incoming: 1024
        reg_l = 0x00; // 0x0400 = 1024
        reg_h = 0x04;
        // max outgoing: 1024
        reg_e = 0x00;
        reg_d = 0x04;
        reg_a = ERR_OK;
        break;

    case 4: // Second capabilities set
        reg_l = 0; reg_h = 0;
        reg_e = 0; reg_d = 0;
        reg_a = ERR_OK;
        break;

    default:
        reg_a = ERR_INV_PARAM;
        break;
    }
}

// --- Función 2: TCPIP_GET_IPINFO ---
// Entrada: B = índice (1=local, 2=peer, 3=mask, 4=gw, 5=dns1, 6=dns2)
// Salida: L.H.E.D = IP address
static void fn_get_ipinfo(void)
{
    if (reg_b == 1) {
        // Local IP → pedir al bridge
        bridge_cmd(CMD_GET_LOCALIP);
        if (bridge_status() == STATUS_DATA) {
            reg_l = bridge_read(); // octet 1
            reg_h = bridge_read(); // octet 2
            reg_e = bridge_read(); // octet 3
            reg_d = bridge_read(); // octet 4
            reg_a = ERR_OK;
        } else {
            reg_l = 0; reg_h = 0; reg_e = 0; reg_d = 0;
            reg_a = ERR_OK;
        }
    } else if (reg_b == 3) {
        // Subnet mask: 255.255.255.0
        reg_l = 255; reg_h = 255; reg_e = 255; reg_d = 0;
        reg_a = ERR_OK;
    } else if (reg_b == 4) {
        // Default gateway: same as local IP with .1
        bridge_cmd(CMD_GET_LOCALIP);
        if (bridge_status() == STATUS_DATA) {
            reg_l = bridge_read();
            reg_h = bridge_read();
            reg_e = bridge_read();
            bridge_read();         // descartar octet 4
            reg_d = 1;             // .1
            reg_a = ERR_OK;
        } else {
            reg_l = 0; reg_h = 0; reg_e = 0; reg_d = 0;
            reg_a = ERR_OK;
        }
    } else if (reg_b == 5 || reg_b == 6) {
        // DNS servers: 8.8.8.8 / 8.8.4.4
        reg_l = 8; reg_h = 8;
        reg_e = (reg_b == 5) ? 8 : 4;
        reg_d = (reg_b == 5) ? 8 : 4;
        reg_a = ERR_OK;
    } else {
        // Peer IP o índice inválido
        reg_l = 0; reg_h = 0; reg_e = 0; reg_d = 0;
        reg_a = ERR_OK;
    }
}

// --- Función 3: TCPIP_NET_STATE ---
// Salida: B = estado (0=closed, 1=opening, 2=open, 3=closing)
static void fn_net_state(void)
{
    bridge_cmd(CMD_NET_STATE);
    if (bridge_status() == STATUS_DATA) {
        reg_b = bridge_read();
    } else {
        reg_b = 2; // asumir open
    }
    reg_a = ERR_OK;
}

// --- Función 6: TCPIP_DNS_Q ---
// Entrada: HL = dirección del hostname, B = flags
// Salida:  A = error, B = status, L.H.E.D = IP (si resuelto)
static void fn_dns_q(void)
{
    u16 addr = ((u16)reg_h << 8) | reg_l;
    u8 flags = reg_b;

    // Bit 0: abort current query
    // Bit 1: assume IP string
    // Bit 2: don't abort if query in progress

    // Escribir hostname al bridge byte a byte
    u8 ch;
    do {
        ch = *(u8*)addr;
        bridge_write(ch);
        addr++;
    } while (ch != 0);

    // Enviar comando DNS_QUERY
    bridge_cmd(CMD_DNS_QUERY);

    if (bridge_status() == STATUS_DATA) {
        u8 result = bridge_read();
        reg_a = ERR_OK;
        reg_b = result; // 0=in_progress, 1=immediate, 2=local

        if (result == 1 || result == 2) {
            // IP resuelta inmediatamente
            reg_l = bridge_read();
            reg_h = bridge_read();
            reg_e = bridge_read();
            reg_d = bridge_read();
        }
    } else {
        reg_a = ERR_QUERY_EXISTS;
    }
}

// --- Función 7: TCPIP_DNS_S ---
// Entrada: B = flags (bit 0: clear after read)
// Salida:  A = error, B = status, C = substatus, L.H.E.D = IP
static void fn_dns_s(void)
{
    bridge_cmd(CMD_DNS_STATUS);

    if (bridge_status() != STATUS_DATA) {
        reg_a = ERR_OK;
        reg_b = 0; // no query
        return;
    }

    u8 status = bridge_read();

    if (status == 2) {
        // Resolución completa
        reg_a = ERR_OK;
        reg_b = 2;
        reg_c = 0; // DNS server query
        reg_l = bridge_read();
        reg_h = bridge_read();
        reg_e = bridge_read();
        reg_d = bridge_read();
    } else if (status == 0xFF) {
        // Error DNS
        u8 dns_err = bridge_read();
        reg_a = ERR_DNS;
        reg_b = dns_err;
    } else if (status == 1) {
        // En progreso
        reg_a = ERR_OK;
        reg_b = 1;
        reg_c = 1; // querying primary DNS
    } else {
        // Idle
        reg_a = ERR_OK;
        reg_b = 0;
    }
}

// --- Función 13: TCPIP_TCP_OPEN ---
// Entrada: HL = puntero a bloque de parámetros (13 bytes)
//   +0: IP remota (4 bytes)
//   +4: Puerto remoto (2 bytes LE)
//   +6: Puerto local (2 bytes LE)
//   +8: Timeout (2 bytes LE)
//   +10: Flags (1 byte)
// Salida: A = error, B = handle
static void fn_tcp_open(void)
{
    u16 addr = ((u16)reg_h << 8) | reg_l;

    // Leer parámetros desde RAM del MSX
    u8 ip0   = *(u8*)(addr + 0);
    u8 ip1   = *(u8*)(addr + 1);
    u8 ip2   = *(u8*)(addr + 2);
    u8 ip3   = *(u8*)(addr + 3);
    u8 plo   = *(u8*)(addr + 4); // remote port low
    u8 phi   = *(u8*)(addr + 5); // remote port high

    // Escribir parámetros al bridge: IP[4] + port[2 LE]
    bridge_write(ip0);
    bridge_write(ip1);
    bridge_write(ip2);
    bridge_write(ip3);
    bridge_write(plo);
    bridge_write(phi);

    // Enviar comando
    bridge_cmd(CMD_TCP_OPEN);

    if (bridge_status() == STATUS_DATA) {
        u8 handle = bridge_read();
        if (handle > 0) {
            // Marcar como activo localmente
            if (handle <= MAX_TCP) {
                tcp_active[handle - 1] = 1;
            }
            reg_a = ERR_OK;
            reg_b = handle;
        } else {
            reg_a = ERR_NO_FREE_CONN;
        }
    } else {
        reg_a = ERR_NO_FREE_CONN;
    }
}

// --- Función 14: TCPIP_TCP_CLOSE ---
// Entrada: B = handle (0 = cerrar todas transient)
// Salida:  A = error
static void fn_tcp_close(void)
{
    u8 handle = reg_b;

    bridge_write(handle);
    bridge_cmd(CMD_TCP_CLOSE);

    if (bridge_status() == STATUS_DATA) {
        bridge_read(); // consumir status byte
        if (handle == 0) {
            // Cerrar todas
            for (u8 i = 0; i < MAX_TCP; i++) {
                tcp_active[i] = 0;
            }
        } else if (handle <= MAX_TCP) {
            tcp_active[handle - 1] = 0;
        }
        reg_a = ERR_OK;
    } else {
        reg_a = ERR_NO_CONN;
    }
}

// --- Función 15: TCPIP_TCP_ABORT ---
// Entrada: B = handle
// Salida:  A = error
static void fn_tcp_abort(void)
{
    u8 handle = reg_b;

    if (handle < 1 || handle > MAX_TCP) {
        reg_a = ERR_NO_CONN;
        return;
    }

    bridge_write(handle);
    bridge_cmd(CMD_TCP_ABORT);

    if (bridge_status() == STATUS_DATA) {
        bridge_read(); // consumir status
        tcp_active[handle - 1] = 0;
        reg_a = ERR_OK;
    } else {
        reg_a = ERR_NO_CONN;
    }
}

// --- Función 16: TCPIP_TCP_STATE ---
// Entrada: B = handle, HL = puntero a info block (0 = no)
// Salida:  A = error, B = state, C = flags/close_reason,
//          HL = bytes disponibles, DE = urgent bytes
static void fn_tcp_state(void)
{
    u8 handle = reg_b;
    u16 info_addr = ((u16)reg_h << 8) | reg_l;

    if (handle < 1 || handle > MAX_TCP) {
        reg_a = ERR_NO_CONN;
        reg_b = 0;   // CLOSED
        reg_c = 1;   // never used
        return;
    }

    bridge_write(handle);
    bridge_cmd(CMD_TCP_STATE);

    if (bridge_status() == STATUS_DATA) {
        u8 state       = bridge_read();
        u8 avail_lo    = bridge_read();
        u8 avail_hi    = bridge_read();
        u8 close_reason = bridge_read();

        reg_a = ERR_OK;
        reg_b = state;
        reg_c = close_reason;
        reg_l = avail_lo;  // HL = available incoming bytes
        reg_h = avail_hi;
        reg_e = 0;         // DE = urgent bytes (no soportamos)
        reg_d = 0;

        // Si state == CLOSED, marcar libre localmente
        if (state == 0 && handle <= MAX_TCP) {
            tcp_active[handle - 1] = 0;
        }
    } else {
        reg_a = ERR_NO_CONN;
        reg_b = 0;
        reg_c = 1;
    }
}

// --- Función 17: TCPIP_TCP_SEND ---
// Entrada: B = handle, DE = dirección datos, HL = longitud, C = flags
// Salida:  A = error
static void fn_tcp_send(void)
{
    u8  handle   = reg_b;
    u16 data_addr = ((u16)reg_d << 8) | reg_e;
    u16 length    = ((u16)reg_h << 8) | reg_l;

    if (handle < 1 || handle > MAX_TCP) {
        reg_a = ERR_NO_CONN;
        return;
    }

    // Limitar tamaño por transferencia
    if (length > 1024) length = 1024;

    // Escribir parámetros: handle + len[2 LE] + data
    bridge_write(handle);
    bridge_write((u8)(length & 0xFF));
    bridge_write((u8)((length >> 8) & 0xFF));

    for (u16 i = 0; i < length; i++) {
        bridge_write(*(u8*)(data_addr + i));
    }

    bridge_cmd(CMD_TCP_SEND);

    if (bridge_status() == STATUS_DATA) {
        u8 result = bridge_read();
        reg_a = (result == 0) ? ERR_OK : ERR_CONN_STATE;
    } else {
        reg_a = ERR_CONN_STATE;
    }
}

// --- Función 18: TCPIP_TCP_RCV ---
// Entrada: B = handle, DE = dirección buffer, HL = longitud máxima
// Salida:  A = error, BC = bytes recibidos, HL = urgent bytes
static void fn_tcp_rcv(void)
{
    u8  handle   = reg_b;
    u16 buf_addr  = ((u16)reg_d << 8) | reg_e;
    u16 maxlen    = ((u16)reg_h << 8) | reg_l;

    if (handle < 1 || handle > MAX_TCP) {
        reg_a = ERR_NO_CONN;
        reg_b = 0; reg_c = 0;
        return;
    }

    if (maxlen > 1024) maxlen = 1024;

    // Escribir parámetros: handle + maxlen[2 LE]
    bridge_write(handle);
    bridge_write((u8)(maxlen & 0xFF));
    bridge_write((u8)((maxlen >> 8) & 0xFF));

    bridge_cmd(CMD_TCP_RECV);

    if (bridge_status() == STATUS_DATA) {
        u8 len_lo = bridge_read();
        u8 len_hi = bridge_read();
        u16 actual = ((u16)len_hi << 8) | len_lo;

        // Copiar datos al buffer del MSX
        for (u16 i = 0; i < actual; i++) {
            *(u8*)(buf_addr + i) = bridge_read();
        }

        reg_a = ERR_OK;
        reg_b = (u8)((actual >> 8) & 0xFF); // BC = actual bytes
        reg_c = (u8)(actual & 0xFF);
        reg_h = 0; reg_l = 0; // HL = urgent (none)
    } else {
        reg_a = ERR_NO_DATA;
        reg_b = 0; reg_c = 0;
        reg_h = 0; reg_l = 0;
    }
}

// ============================================================
//  Dispatcher C  (llamado desde el dispatcher ASM)
//  Lee reg_a para el número de función y despacha.
// ============================================================

static void dispatch_unapi(void)
{
    switch (reg_a) {
    case  0: fn_get_info();   break;
    case  1: fn_get_capab();  break;
    case  2: fn_get_ipinfo(); break;
    case  3: fn_net_state();  break;
    case  6: fn_dns_q();      break;
    case  7: fn_dns_s();      break;
    case 13: fn_tcp_open();   break;
    case 14: fn_tcp_close();  break;
    case 15: fn_tcp_abort();  break;
    case 16: fn_tcp_state();  break;
    case 17: fn_tcp_send();   break;
    case 18: fn_tcp_rcv();    break;
    default:
        reg_a = ERR_NOT_IMP;
        break;
    }
}

// ============================================================
//  Bloque de identificación UNAPI (residente en RAM)
//
//  Formato (spec Konamiman):
//    +00  JP dispatch   (3 bytes, parchados en runtime)
//    +03  "TCPIP\0"     (firma)
//    +09  ver_main, ver_sec
//
//  Ubicado en 0x8000 para estar en la zona residente.
// ============================================================

__at(0x8000) static u8 unapi_id_block[] = {
    0xC3, 0x00, 0x00,                     // JP dispatcher (parchado)
    'T','C','P','I','P', 0x00,            // firma UNAPI
    UNAPI_VER_MAIN, UNAPI_VER_SEC         // versión
};

// ============================================================
//  Dispatcher UNAPI (entry point naked ASM)
//
//  Cuando un cliente UNAPI llama al entry point, los registros
//  contienen los parámetros de la función UNAPI.
//  A = número de función.
//
//  Guardamos todos los registros en las variables globales,
//  llamamos al dispatcher C, y restauramos los registros
//  de salida.
// ============================================================

void unapi_dispatch(void) __naked
{
    __asm

    ;; ---- Guardar registros de entrada ----
    ld      (_reg_a), a
    ld      a, b
    ld      (_reg_b), a
    ld      a, c
    ld      (_reg_c), a
    ld      a, d
    ld      (_reg_d), a
    ld      a, e
    ld      (_reg_e), a
    ld      a, h
    ld      (_reg_h), a
    ld      a, l
    ld      (_reg_l), a

    ;; ---- Llamar dispatcher C ----
    call    _dispatch_unapi

    ;; ---- Cargar registros de salida ----
    ld      a, (_reg_b)
    ld      b, a
    ld      a, (_reg_c)
    ld      c, a
    ld      a, (_reg_d)
    ld      d, a
    ld      a, (_reg_e)
    ld      e, a
    ld      a, (_reg_h)
    ld      h, a
    ld      a, (_reg_l)
    ld      l, a

    ;; A (error code) se carga último
    ld      a, (_reg_a)
    ret

    __endasm;
}

// ============================================================
//  Hook EXTBIO  –  Protocolo UNAPI discovery
//
//  Cuando un programa llama a EXTBIO (0xFFCA) con DE=0x2222:
//    Si A=0: contar implementaciones (incrementar A)
//    Si A>0: devolver entry point de la implementación #A
//
//  Para otras llamadas EXTBIO: encadenar al hook previo.
// ============================================================

static u8 prev_extbio[5]; // hook previo (5 bytes)

void extbio_hook(void) __naked
{
    __asm

    ;; ---- Comprobar si es llamada UNAPI (DE = 0x2222) ----
    push    af
    ld      a, d
    cp      #0x22
    jr      nz, _extbio_chain
    ld      a, e
    cp      #0x22
    jr      nz, _extbio_chain
    pop     af

    ;; ---- Es llamada UNAPI. Comprobar firma en HL ----
    ;; HL apunta a la cadena de API que busca el caller.
    ;; Comparar con "TCPIP"
    push    de
    push    hl

    ld      de, #_sig_tcpip
    ld      b, #6          ; 5 chars + null

_extbio_cmp:
    ld      a, (de)
    cp      (hl)
    jr      nz, _extbio_nomatch
    inc     hl
    inc     de
    djnz    _extbio_cmp

    ;; ---- Firma coincide. Comprobar A ----
    pop     hl
    pop     de

    ;; Recuperar A original (fue consumido por el pop anterior)
    ;; A está en el stack... necesitamos re-leer.
    ;; En realidad, en el protocolo UNAPI:
    ;;   Al llegar aquí, A = índice de implementación
    ;;   Si A == 0: estamos contando → incrementar A y seguir cadena
    ;;   Si A == 1: somos nosotros → devolver entry point
    ;;   Si A > 1: decrementar A y seguir cadena

    or      a
    jr      z, _extbio_count

    cp      #1
    jr      z, _extbio_getentry

    ;; A > 1: decrementar y pasar al siguiente
    dec     a
    jp      _extbio_prev

_extbio_count:
    ;; Incrementar contador de implementaciones
    inc     a
    jp      _extbio_prev

_extbio_getentry:
    ;; Devolver nuestro entry point
    ;; HL = dirección del bloque UNAPI (0x8000)
    ;; A  = slot del entry point (0 = RAM actual)
    ;; B  = 0xFF (implementación en RAM, sin segmento)
    ld      hl, #0x8000
    xor     a              ; slot 0 = RAM
    ld      b, #0xFF       ; sin segmento
    ret

_extbio_nomatch:
    ;; No coincide firma, restaurar y encadenar
    pop     hl
    pop     de
    jp      _extbio_prev

_extbio_chain:
    pop     af
    ;; fall through to _extbio_prev

_extbio_prev:
    ;; Saltar al hook EXTBIO previo
    ;; Los 5 bytes del hook previo están en _prev_extbio
    ;; Si el primer byte es 0xC9 (RET), simplemente retornar
    ld      a, (_prev_extbio)
    cp      #0xC9
    ret     z
    ;; Si es JP (0xC3), saltar allí
    jp      _prev_extbio

    ;; ---- Cadena de firma para comparación ----
_sig_tcpip:
    .ascii  "TCPIP"
    .db     0

    __endasm;
}

// ============================================================
//  Instalación de hooks
// ============================================================

static void install_hooks(void)
{
    // Guardar hook EXTBIO actual (5 bytes)
    u8* extbio = (u8*)EXTBIO_HOOK;
    for (u8 i = 0; i < 5; i++) {
        prev_extbio[i] = extbio[i];
    }

    // Instalar nuestro hook: JP extbio_hook
    extbio[0] = 0xC3;                                // JP
    extbio[1] = (u8)((u16)extbio_hook & 0xFF);       // low byte
    extbio[2] = (u8)((u16)extbio_hook >> 8);          // high byte
    extbio[3] = 0x00;                                 // NOP padding
    extbio[4] = 0x00;
}

// ============================================================
//  Parchear bloque UNAPI ID (JP al dispatcher)
// ============================================================

static void patch_id_block(void)
{
    u8* block = (u8*)0x8000;
    block[0] = 0xC3;
    block[1] = (u8)((u16)unapi_dispatch & 0xFF);
    block[2] = (u8)((u16)unapi_dispatch >> 8);
}

// ============================================================
//  Quedarse residente (TSR)
//  DOS función 0x31: KEEP (quedar residente)
// ============================================================

static void go_resident(void) __naked
{
    // MSX-DOS 2 función 0x62: _TERM con código 0
    // Quedarse residente con la llamada correcta de Nextor/DOS2
    // DE = dirección final de la parte residente
    __asm
        ld      c, #0x62        ; _TERM (MSX-DOS 2)
        ld      b, #0x00        ; exit code 0
        call    #0x0005
        ret                     ; por si acaso
    __endasm;
}

// ============================================================
//  main()  –  punto de entrada transitorio
// ============================================================

void main(void)
{
    dos_print("UNAPINET v0.2 - UNAPI TCPIP bridge para openMSX\r\n");

    // 1. Detectar extensión openMSX
    dos_print("Buscando extension UnapiNet...");
    if (!detect_extension()) {
        dos_print(" NO ENCONTRADA\r\n");
        dos_print("Carga la extension: ext unapinet\r\n");
        // Salir con error
        __asm
            ld      c, #0x00    ; BDOS función 0: system reset
            call    #0x0005
        __endasm;
        return;
    }
    dos_print(" OK\r\n");

    // 2. Mostrar capacidades
    bridge_cmd(CMD_QUERY_CAP);
    if (bridge_status() == STATUS_DATA) {
        u8 cap0 = bridge_read();
        u8 cap1 = bridge_read();
        dos_print("Caps: TCP=");
        dos_print((cap0 & 0x01) ? "SI" : "NO");
        dos_print(" UDP=");
        dos_print((cap0 & 0x02) ? "SI" : "NO");
        dos_print(" DNS=");
        dos_print((cap0 & 0x04) ? "SI" : "NO");
        dos_print(" Bridge v");
        dos_putchar('0' + cap1);
        dos_print("\r\n");
    }

    // 3. Parchear bloque UNAPI ID
    patch_id_block();

    // 4. Instalar hook EXTBIO
    dos_print("Instalando hook EXTBIO...");
    install_hooks();
    dos_print(" OK\r\n");

    // 5. Inicializar estado local
    for (u8 i = 0; i < MAX_TCP; i++) {
        tcp_active[i] = 0;
    }

    dos_print("UNAPI TCPIP activo. Funciones: DNS, TCP\r\n");
    dos_print("TSR residente instalado.\r\n");

    // 6. Quedarse residente
    go_resident();
}
