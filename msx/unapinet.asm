;============================================================
; UNAPINET.ASM — TSR UNAPI TCP/IP para openMSX
; Basado en unapi-ram.asm de Konamiman (UNAPI spec 1.1)
;
; Se instala en un segmento del memory mapper.
; Requiere RAM helper previamente instalado (RAMHELPR.COM).
; Despacha funciones UNAPI TCP/IP via puertos I/O 28h/29h
; (mismo rango que el DenYoNet — ambos son bridges UNAPI Ethernet y
;  no se cargan a la vez). Iteraciones previas usaron 7Eh/7Fh
;  (choque con MoonSound), C0h/C1h (choque con DalSoRi R2) y 0Bh/0Ch
;  (causa desconocida pero no funcionó in-situ). Comunica con la
;  extensión C++ UnapiNet de openMSX.
;
; Compilar: N80 unapinet.asm unapinet.com --direct-output-write
;============================================================

;*******************
;***  CONSTANTS  ***
;*******************

_TERM0:  equ     00h
_STROUT: equ     09h

ENASLT: equ     0024h
EXTBIO: equ     0FFCAh
ARG:    equ     0F847h

; --- API / Implementation version
API_V_P:        equ     1
API_V_S:        equ     1
ROM_V_P:        equ     1
ROM_V_S:        equ     1

; --- Max function number
MAX_FN:         equ     18
MAX_IMPFN:      equ     0

; --- I/O ports (must match unapinet.xml)
IO_CMD:         equ     28h     ; W=command, R=status
IO_DATA:        equ     29h     ; W=param,   R=result

; --- Bridge commands
CMD_PING:       equ     00h
CMD_DNS_QUERY:  equ     01h
CMD_DNS_STATUS: equ     02h
CMD_TCP_OPEN:   equ     03h
CMD_TCP_SEND:   equ     04h
CMD_TCP_RECV:   equ     05h
CMD_TCP_CLOSE:  equ     06h
CMD_TCP_STATE:  equ     07h
CMD_TCP_ABORT:  equ     08h
CMD_UDP_OPEN:   equ     09h
CMD_UDP_CLOSE:  equ     0Ah
CMD_UDP_STATE:  equ     0Bh
CMD_UDP_SEND:   equ     0Ch
CMD_GET_LOCALIP: equ    0Dh
CMD_NET_STATE:  equ     0Eh
CMD_UDP_RECV:   equ     0Fh
CMD_ICMP_SEND:  equ     11h
CMD_ICMP_RECV:  equ     12h

; --- Bridge status
STATUS_OK:      equ     00h
STATUS_ERROR:   equ     01h
STATUS_DATA:    equ     02h
PING_MAGIC:     equ     0ABh

; --- UNAPI error codes
ERR_OK:         equ     0
ERR_NOT_IMP:    equ     1
ERR_NO_NETWORK: equ     2
ERR_NO_DATA:    equ     3
ERR_INV_PARAM:  equ     4
ERR_QUERY_EXISTS: equ   5
ERR_NO_FREE_CONN: equ   9
ERR_NO_CONN:    equ     11
ERR_CONN_STATE: equ     12


;***************************
;***  INSTALLATION CODE  ***
;***************************

        org     100h

        ;--- Detect openMSX extension first

        ld      a,CMD_PING
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,NO_EXT
        in      a,(IO_DATA)
        cp      PING_MAGIC
        jr      z,EXT_OK

NO_EXT:
        ld      de,NOEXT_S
        ld      c,_STROUT
        call    5
        ld      c,_TERM0
        jp      5

EXT_OK:
        ;--- Show welcome message

        ld      de,WELCOME_S
        ld      c,_STROUT
        call    5

        ;--- Locate the RAM helper

        ld      de,2222h
        ld      hl,0
        ld      a,0FFh
        call    EXTBIO
        ld      a,h
        or      l
        jr      nz,HELPER_OK

        ld      de,NOHELPER_S
        ld      c,_STROUT
        call    5
        ld      c,_TERM0
        jp      5
HELPER_OK:
        ld      (HELPER_ADD),hl
        ld      (MAPTAB_ADD),bc

        ;--- Check if already installed

        ld      hl,UNAPI_ID-SEG_CODE_START+SEG_CODE
        ld      de,ARG
        ld      bc,UNAPI_ID_END-UNAPI_ID
        ldir

        ld      de,2222h
        xor     a
        ld      b,0
        call    EXTBIO
        ld      a,b
        or      a
        jr      z,NOT_INST

IMPL_LOOP:      push    af

        ld      de,2222h
        call    EXTBIO
        ld      (ALLOC_SLOT),a
        ld      a,b
        ld      (ALLOC_SEG),a
        ld      (IMPLEM_ENTRY),hl

        ; Skip page 3 or ROM implementations
        ld      a,h
        and     10000000b
        jr      nz,NEXT_IMP
        ld      a,b
        cp      0FFh
        jr      z,NEXT_IMP

        ; Call fn 0 to get implementation name
        ld      a,(ALLOC_SLOT)
        ld      iyh,a
        ld      a,(ALLOC_SEG)
        ld      iyl,a
        ld      ix,(IMPLEM_ENTRY)
        ld      hl,(HELPER_ADD)
        xor     a
        call    CALL_HL

        ; Compare name
        ld      a,(ALLOC_SEG)
        ld      b,a
        ld      de,APIINFO-SEG_CODE_START+SEG_CODE
        ld      ix,(HELPER_ADD)
        inc     ix
        inc     ix
        inc     ix
NAME_LOOP:      ld      a,(ALLOC_SLOT)
        push    bc
        push    de
        push    hl
        push    ix
        call    CALL_IX
        pop     ix
        pop     hl
        pop     de
        pop     bc
        ld      c,a
        ld      a,(de)
        cp      c
        jr      nz,NEXT_IMP
        or      a
        inc     hl
        inc     de
        jr      nz,NAME_LOOP

        ; Already installed
        ld      de,ALINST_S
        ld      c,_STROUT
        call    5
        ld      c,_TERM0
        jp      5

NEXT_IMP:       pop     af
        dec     a
        jr      nz,IMPL_LOOP

NOT_INST:

        ;--- Obtain mapper support routines

        xor     a
        ld      de,0402h
        call    EXTBIO
        or      a
        jr      nz,ALLOC_DOS2

        ;--- DOS 1: last segment on primary mapper

        ld      a,2
        ld      (MAPTAB_ENTRY_SIZE),a

        ld      hl,(MAPTAB_ADD)
        ld      b,(hl)
        inc     hl
        ld      a,(hl)
        jr      ALLOC_OK

        ;--- DOS 2: allocate segment

ALLOC_DOS2:
        ld      a,b
        ld      (PRIM_SLOT),a
        ld      de,ALL_SEG
        ld      bc,15*3
        ldir

        ld      de,0401h
        call    EXTBIO
        ld      (MAPTAB_ADD),hl

        ld      a,8
        ld      (MAPTAB_ENTRY_SIZE),a

        ld      a,(PRIM_SLOT)
        or      00100000b       ; primary mapper, try others
        ld      b,a
        ld      a,1             ; system segment
        call    ALL_SEG
        jr      nc,ALLOC_OK

        ld      de,NOFREE_S
        ld      c,_STROUT
        call    5
        ld      c,_TERM0
        jp      5

ALLOC_OK:
        ld      (ALLOC_SEG),a
        ld      a,b
        ld      (ALLOC_SLOT),a

        ;--- Switch segment, copy code, setup

        call    GET_P1
        ld      (P1_SEG),a

        ld      a,(ALLOC_SLOT)
        ld      h,40h
        call    ENASLT
        ld      a,(ALLOC_SEG)
        call    PUT_P1

        ld      hl,4000h        ; clear segment
        ld      de,4001h
        ld      bc,4000h-1
        ld      (hl),0
        ldir

        ld      hl,SEG_CODE     ; copy code
        ld      de,4000h
        ld      bc,SEG_CODE_END-SEG_CODE_START
        ldir

        ld      hl,(ALLOC_SLOT) ; patch slot+seg
        ld      (MY_SLOT),hl

        ; Backup and patch EXTBIO hook

        ld      hl,EXTBIO
        ld      de,OLD_EXTBIO
        ld      bc,5
        ldir

        di
        ld      a,0CDh          ; CALL
        ld      (EXTBIO),a
        ld      hl,(HELPER_ADD)
        ld      bc,6
        add     hl,bc           ; segment call routine
        ld      (EXTBIO+1),hl

        ld      hl,(MAPTAB_ADD)
        ld      a,(ALLOC_SLOT)
        ld      bc,(MAPTAB_ENTRY_SIZE)
        ld      b,0
        ld      d,a
        ld      e,0
SRCHMAP:
        ld      a,(hl)
        cp      d
        jr      z,MAPFND
        add     hl,bc
        inc     e
        jr      SRCHMAP
MAPFND:
        ld      a,e
        rrca
        rrca
        and     11000000b       ; entry point 4000h = index 0
        ld      (EXTBIO+3),a

        ld      a,(ALLOC_SEG)
        ld      (EXTBIO+4),a
        ei

        ;--- Restore and terminate

        ld      a,(PRIM_SLOT)
        ld      h,40h
        call    ENASLT
        ld      a,(P1_SEG)
        call    PUT_P1

        ld      de,OK_S
        ld      c,_STROUT
        call    5

        ld      c,_TERM0
        jp      5


CALL_IX:        jp      (ix)
CALL_HL:        jp      (hl)


;****************************************************
;***  DATA AND STRINGS FOR THE INSTALLATION CODE  ***
;****************************************************

PRIM_SLOT:      db      0
P1_SEG:         db      0
ALLOC_SLOT:     db      0
ALLOC_SEG:      db      0
HELPER_ADD:     dw      0
MAPTAB_ADD:     dw      0
MAPTAB_ENTRY_SIZE: db   0
IMPLEM_ENTRY:   dw      0

;--- Mapper support routines (filled at install time)

ALL_SEG:        ds      3
FRE_SEG:        ds      3
RD_SEG:         ds      3
WR_SEG:         ds      3
CAL_SEG:        ds      3
CALLS:          ds      3
PUT_PH:         ds      3
GET_PH:         ds      3
PUT_P0:         ds      3
GET_P0:         ds      3
PUT_P1: jp _PUT_P1
GET_P1: ld a,2
        ret
PUT_P2:         ds      3
GET_P2:         ds      3
PUT_P3:         ds      3
_PUT_P1:
        ld      (GET_P1+1),a
        out     (0FDh),a
        ret

;--- Strings

WELCOME_S:
        db      "UNAPINET v1.1 - UNAPI TCP/IP bridge for openMSX",13,10
        db      "(c) 2026 openMSXnet project",13,10
        db      13,10,"$"

NOEXT_S:
        db      "ERROR: openMSX UnapiNet extension not found.",13,10
        db      "Load it with: ext unapinet",13,10,"$"

NOHELPER_S:
        db      "ERROR: No UNAPI RAM helper installed.",13,10
        db      "Run RAMHELPR.COM first.",13,10,"$"

NOFREE_S:
        db      "ERROR: No free RAM segment available.",13,10,"$"

OK_S:   db      "UNAPI TCP/IP bridge installed.",13,10,"$"

ALINST_S:
        db      "Already installed.",13,10,"$"


;*********************************************
;***  CODE TO BE INSTALLED ON RAM SEGMENT  ***
;*********************************************

SEG_CODE:
        org     4000h
SEG_CODE_START:


        ;===============================
        ;===  EXTBIO hook execution  ===
        ;===============================

DO_EXTBIO:
        push    hl
        push    bc
        push    af
        ld      a,d
        cp      22h
        jr      nz,JUMP_OLD
        cp      e
        jr      nz,JUMP_OLD

        ; Compare ARG with our API ID
        ld      hl,UNAPI_ID
        ld      de,ARG
LOOP:   ld      a,(de)
        call    TOUPPER
        cp      (hl)
        jr      nz,JUMP_OLD2
        inc     hl
        inc     de
        or      a
        jr      nz,LOOP

        ; A=255: pass through
        pop     af
        push    af
        inc     a
        jr      z,JUMP_OLD2

        ; A=0: count (B++)
        pop     af
        pop     bc
        or      a
        jr      nz,DO_EXTBIO2
        inc     b
        pop     hl
        ld      de,2222h
        jp      OLD_EXTBIO

DO_EXTBIO2:
        ; A=1: return slot, segment, entry point
        dec     a
        jr      nz,DO_EXTBIO3
        pop     hl
        ld      a,(MY_SEG)
        ld      b,a
        ld      a,(MY_SLOT)
        ld      hl,UNAPI_ENTRY
        ld      de,2222h
        ret

        ; A>1: decrement and chain
DO_EXTBIO3:
        pop     hl
        ld      de,2222h
        jp      OLD_EXTBIO

JUMP_OLD2:
        ld      de,2222h
JUMP_OLD:
        pop     af
        pop     bc
        pop     hl

OLD_EXTBIO:
        ds      5


        ;====================================
        ;===  Functions entry point code  ===
        ;====================================

UNAPI_ENTRY:
        push    hl
        push    af
        ; Fast path: fn 29 = TCPIP_WAIT
        cp      29
        jr      z,DISPATCH_WAIT
        ld      hl,FN_TABLE
        bit     7,a
        jr      nz,UNDEFINED

        cp      MAX_FN
        jr      z,OK_FNUM
        jr      nc,UNDEFINED

OK_FNUM:
        add     a,a
        push    de
        ld      e,a
        ld      d,0
        add     hl,de
        pop     de

        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a

        pop     af
        ex      (sp),hl
        ret

UNDEFINED:
        pop     af
        pop     hl
        ld      a,ERR_NOT_IMP
        ei
        ret

DISPATCH_WAIT:
        pop     af
        pop     hl
        jp      FN_WAIT


        ;===================================
        ;===  Functions addresses table  ===
        ;===================================

FN_TABLE:
        dw      FN_INFO         ; 0  UNAPI_GET_INFO
        dw      FN_GET_CAPAB    ; 1  TCPIP_GET_CAPAB
        dw      FN_GET_IPINFO   ; 2  TCPIP_GET_IPINFO
        dw      FN_NET_STATE    ; 3  TCPIP_NET_STATE
        dw      FN_SEND_ECHO    ; 4  TCPIP_SEND_ECHO
        dw      FN_RCV_ECHO     ; 5  TCPIP_RCV_ECHO
        dw      FN_DNS_Q        ; 6  TCPIP_DNS_Q
        dw      FN_DNS_S        ; 7  TCPIP_DNS_S
        dw      FN_UDP_OPEN     ; 8  TCPIP_UDP_OPEN
        dw      FN_UDP_CLOSE    ; 9  TCPIP_UDP_CLOSE
        dw      FN_UDP_STATE    ; 10 TCPIP_UDP_STATE
        dw      FN_UDP_SEND     ; 11 TCPIP_UDP_SEND
        dw      FN_UDP_RCV      ; 12 TCPIP_UDP_RCV
        dw      FN_TCP_OPEN     ; 13 TCPIP_TCP_OPEN
        dw      FN_TCP_CLOSE    ; 14 TCPIP_TCP_CLOSE
        dw      FN_TCP_ABORT    ; 15 TCPIP_TCP_ABORT
        dw      FN_TCP_STATE    ; 16 TCPIP_TCP_STATE
        dw      FN_TCP_SEND     ; 17 TCPIP_TCP_SEND
        dw      FN_TCP_RCV      ; 18 TCPIP_TCP_RCV


        ;========================
        ;===  Functions code  ===
        ;========================

;--- Function 0: UNAPI_GET_INFO
;    Output: HL=name, DE=API version, BC=impl version

FN_INFO:
        ld      bc,256*ROM_V_P+ROM_V_S
        ld      de,256*API_V_P+API_V_S
        ld      hl,APIINFO
        xor     a
        ei
        ret

;--- Function undefined
FN_UNDEF:
        ld      a,ERR_NOT_IMP
        ei
        ret


;--- Function 1: TCPIP_GET_CAPAB
;    Input: B=block (1-4)
;    Output depends on block

FN_GET_CAPAB:
        ld      a,b
        cp      1
        jr      z,.cap1
        cp      2
        jr      z,.cap2
        cp      3
        jr      z,.cap3
        cp      4
        jr      z,.cap4
        ld      a,ERR_INV_PARAM
        ei
        ret

.cap1:  ; Capabilities:
        ; bit0=PING, bit2=DNS, bit3=TCP active,
        ; bit4=TCP passive (specified remote), bit5=TCP passive (unspec remote),
        ; bit10=UDP
        ld      hl,043Dh        ; 0x0400 | 0x0030 | 0x000C | 0x0001
        ld      de,043Dh
        ld      b,0             ; link level: unknown
        xor     a
        ei
        ret

.cap2:  ; Connection pool
        ld      b,4             ; max TCP
        ld      c,4             ; max UDP
        ld      d,4             ; free TCP (approximate)
        ld      e,4             ; free UDP (approximate)
        ld      h,0             ; max raw
        ld      l,0             ; free raw
        xor     a
        ei
        ret

.cap3:  ; Datagram sizes
        ld      hl,0400h        ; max incoming = 1024
        ld      de,0400h        ; max outgoing = 1024
        xor     a
        ei
        ret

.cap4:  ; Second capabilities set
        ld      hl,0
        ld      de,0
        xor     a
        ei
        ret


;--- Function 2: TCPIP_GET_IPINFO
;    Input: B=index (1=local, 3=mask, 5=dns1, etc)
;    Output: L.H.E.D = IP

FN_GET_IPINFO:
        ld      a,b
        cp      1
        jr      z,.ip_local
        cp      3
        jr      z,.ip_mask
        cp      4
        jr      z,.ip_gw
        cp      5
        jr      z,.ip_dns1
        cp      6
        jr      z,.ip_dns2
        ; Peer or unknown: return 0.0.0.0
        ld      hl,0
        ld      de,0
        xor     a
        ei
        ret

.ip_local:
        ld      a,CMD_GET_LOCALIP
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ip_zero
        in      a,(IO_DATA)
        ld      l,a             ; octet 1
        in      a,(IO_DATA)
        ld      h,a             ; octet 2
        in      a,(IO_DATA)
        ld      e,a             ; octet 3
        in      a,(IO_DATA)
        ld      d,a             ; octet 4
        xor     a
        ei
        ret

.ip_mask:
        ld      l,255
        ld      h,255
        ld      e,255
        ld      d,0
        xor     a
        ei
        ret

.ip_gw:
        ; Same as local but .1
        ld      a,CMD_GET_LOCALIP
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ip_zero
        in      a,(IO_DATA)
        ld      l,a
        in      a,(IO_DATA)
        ld      h,a
        in      a,(IO_DATA)
        ld      e,a
        in      a,(IO_DATA)    ; discard octet 4
        ld      d,1
        xor     a
        ei
        ret

.ip_dns1:
        ld      l,8
        ld      h,8
        ld      e,8
        ld      d,8
        xor     a
        ei
        ret

.ip_dns2:
        ld      l,8
        ld      h,8
        ld      e,4
        ld      d,4
        xor     a
        ei
        ret

.ip_zero:
        ld      hl,0
        ld      de,0
        xor     a
        ei
        ret


;--- Function 3: TCPIP_NET_STATE
;    Output: B=state (2=open)

FN_NET_STATE:
        ld      a,CMD_NET_STATE
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ns_open
        in      a,(IO_DATA)
        ld      b,a
        xor     a
        ei
        ret
.ns_open:
        ld      b,2             ; assume open
        xor     a
        ei
        ret


;--- Function 6: TCPIP_DNS_Q
;    Input: HL=hostname ptr, B=flags
;    Output: A=err, B=status, L.H.E.D=IP if resolved

FN_DNS_Q:
        ; Write hostname bytes to data port
        push    hl
.dq_lp: ld      a,(hl)
        out     (IO_DATA),a
        or      a
        jr      z,.dq_done
        inc     hl
        jr      .dq_lp
.dq_done:
        pop     hl

        ; Execute DNS_QUERY
        ld      a,CMD_DNS_QUERY
        out     (IO_CMD),a

        ; Read result
        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.dq_err

        in      a,(IO_DATA)     ; status byte
        ld      b,a
        cp      1
        jr      z,.dq_ip
        cp      2
        jr      z,.dq_ip
        ; status 0 = in progress
        xor     a
        ei
        ret

.dq_ip: ; Read 4 bytes IP
        in      a,(IO_DATA)
        ld      l,a
        in      a,(IO_DATA)
        ld      h,a
        in      a,(IO_DATA)
        ld      e,a
        in      a,(IO_DATA)
        ld      d,a
        xor     a               ; ERR_OK
        ei
        ret

.dq_err:
        ld      a,ERR_QUERY_EXISTS
        ei
        ret


;--- Function 7: TCPIP_DNS_S
;    Input: B=flags
;    Output: A=err, B=status, C=substatus, L.H.E.D=IP

FN_DNS_S:
        ld      a,CMD_DNS_STATUS
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ds_idle

        in      a,(IO_DATA)     ; status
        cp      2
        jr      z,.ds_complete
        cp      0FFh
        jr      z,.ds_error
        cp      1
        jr      z,.ds_progress
        ; idle
.ds_idle:
        ld      b,0
        xor     a
        ei
        ret

.ds_progress:
        ld      b,1
        ld      c,1             ; querying primary DNS
        xor     a
        ei
        ret

.ds_complete:
        ld      b,2
        ld      c,0             ; DNS server query
        in      a,(IO_DATA)
        ld      l,a
        in      a,(IO_DATA)
        ld      h,a
        in      a,(IO_DATA)
        ld      e,a
        in      a,(IO_DATA)
        ld      d,a
        xor     a
        ei
        ret

.ds_error:
        in      a,(IO_DATA)     ; DNS error code
        ld      b,a
        ld      a,8             ; ERR_DNS
        ei
        ret


;--- Function 13: TCPIP_TCP_OPEN
;    Input: HL=param block ptr (11 bytes)
;    Output: A=err, B=handle

FN_TCP_OPEN:
        ; Write full 11-byte param block to bridge:
        ;   IP[4] + remote_port[2] + local_port[2] + timeout[2] + flags[1]
        ld      b,11
.to_lp: ld      a,(hl)
        out     (IO_DATA),a
        inc     hl
        djnz    .to_lp

        ld      a,CMD_TCP_OPEN
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.to_err

        in      a,(IO_DATA)     ; handle
        or      a
        jr      z,.to_err
        ld      b,a
        xor     a               ; ERR_OK
        ei
        ret

.to_err:
        ld      a,ERR_NO_FREE_CONN
        ei
        ret


;--- Function 14: TCPIP_TCP_CLOSE
;    Input: B=handle
;    Output: A=err

FN_TCP_CLOSE:
        ld      a,b
        out     (IO_DATA),a
        ld      a,CMD_TCP_CLOSE
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.tc_err
        in      a,(IO_DATA)     ; consume status byte
        xor     a
        ei
        ret
.tc_err:
        ld      a,ERR_NO_CONN
        ei
        ret


;--- Function 15: TCPIP_TCP_ABORT
;    Input: B=handle
;    Output: A=err

FN_TCP_ABORT:
        ld      a,b
        out     (IO_DATA),a
        ld      a,CMD_TCP_ABORT
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ta_err
        in      a,(IO_DATA)     ; consume status byte
        xor     a
        ei
        ret
.ta_err:
        ld      a,ERR_NO_CONN
        ei
        ret


;--- Function 16: TCPIP_TCP_STATE
;    Input: B=handle, HL=info block ptr (0=not needed)
;    Output: A=err, B=state, C=close_reason, HL=avail, DE=urgent

FN_TCP_STATE:
        ld      a,b
        out     (IO_DATA),a
        ld      a,CMD_TCP_STATE
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ts_err

        ; Read 12-byte response from bridge:
        ;   state, avail[2], close_reason,
        ;   remote_ip[4], remote_port[2], local_port[2]
        ; Per UNAPI spec, we return:
        ;   A=err, B=state, C=close_reason,
        ;   HL=avail bytes, DE=urgent (always 0 for us),
        ;   IX=send buffer free space (use a large value)
        ; The 8 bytes of remote/local info are read and discarded;
        ; we don't have a way to convey them back through the standard
        ; UNAPI register interface used by MSXgl-style helpers.

        in      a,(IO_DATA)     ; state
        ld      b,a
        in      a,(IO_DATA)     ; avail low
        ld      l,a
        in      a,(IO_DATA)     ; avail high
        ld      h,a
        in      a,(IO_DATA)     ; close reason
        ld      c,a
        ; discard the next 8 bytes (remote IP/port/local port)
        push    bc
        ld      b,8
.ts_dlp: in     a,(IO_DATA)
        djnz    .ts_dlp
        pop     bc
        ld      de,0            ; no urgent data
        ld      ix,0FFFFh       ; "infinite" send buffer free space
        xor     a
        ei
        ret

.ts_err:
        ld      b,0             ; CLOSED
        ld      c,1             ; never used
        ld      hl,0
        ld      de,0
        ld      ix,0
        ld      a,ERR_NO_CONN
        ei
        ret


;--- Function 17: TCPIP_TCP_SEND
;    Input: B=handle, DE=data ptr, HL=length, C=flags
;    Output: A=err

FN_TCP_SEND:
        ; Write: handle, len_lo, len_hi
        ld      a,b
        out     (IO_DATA),a
        ld      a,l
        out     (IO_DATA),a
        ld      a,h
        out     (IO_DATA),a

        ; Write data bytes from (DE), length in HL
        push    hl
        pop     bc              ; BC = length
        ex      de,hl           ; HL = data source

.ts_lp: ld      a,b
        or      c
        jr      z,.ts_exec
        ld      a,(hl)
        out     (IO_DATA),a
        inc     hl
        dec     bc
        jr      .ts_lp

.ts_exec:
        ld      a,CMD_TCP_SEND
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ts_serr
        in      a,(IO_DATA)     ; 0=ok, 1=error
        or      a
        ret     z               ; A=0 = ERR_OK
        ld      a,ERR_CONN_STATE
        ei
        ret
.ts_serr:
        ld      a,ERR_CONN_STATE
        ei
        ret


;--- Function 18: TCPIP_TCP_RCV
;    Input: B=handle, DE=buffer ptr, HL=max length
;    Output: A=err, BC=actual bytes, HL=urgent

FN_TCP_RCV:
        ; Save DE (buffer ptr)
        push    de

        ; Write: handle, maxlen_lo, maxlen_hi
        ld      a,b
        out     (IO_DATA),a
        ld      a,l
        out     (IO_DATA),a
        ld      a,h
        out     (IO_DATA),a

        ld      a,CMD_TCP_RECV
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.tr_nodata

        ; Read actual length (2 bytes LE)
        in      a,(IO_DATA)
        ld      c,a             ; len low
        in      a,(IO_DATA)
        ld      b,a             ; len high

        ; Copy data bytes to user buffer at (DE)
        pop     de              ; restore buffer ptr
        push    bc              ; save actual length

        ; BC = actual length, DE = destination
.tr_lp: ld      a,b
        or      c
        jr      z,.tr_done
        in      a,(IO_DATA)
        ld      (de),a
        inc     de
        dec     bc
        jr      .tr_lp

.tr_done:
        pop     bc              ; BC = actual length
        ld      hl,0            ; no urgent data
        xor     a               ; ERR_OK
        ei
        ret

.tr_nodata:
        pop     de
        ld      bc,0
        ld      hl,0
        ld      a,ERR_NO_DATA
        ei
        ret


;--- Function 4: TCPIP_SEND_ECHO
;    Input: HL = parameter block (11 bytes)
;      +0..+3: IP, +4: TTL, +5..+6: ID, +7..+8: SEQ, +9..+10: len
;    Output: A = err

FN_SEND_ECHO:
        ld      b,11
.se_lp: ld      a,(hl)
        out     (IO_DATA),a
        inc     hl
        djnz    .se_lp

        ld      a,CMD_ICMP_SEND
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.se_err
        in      a,(IO_DATA)     ; status byte from bridge
        or      a
        jr      nz,.se_err
        xor     a               ; ERR_OK
        ei
        ret
.se_err:
        ld      a,ERR_NO_NETWORK
        ei
        ret


;--- Function 5: TCPIP_RCV_ECHO
;    Input: HL = buffer (11 bytes) for received echo data
;    Output: A = err (ERR_OK if got reply, ERR_NO_DATA if queue empty)

FN_RCV_ECHO:
        push    hl              ; save user buffer
        ld      a,CMD_ICMP_RECV
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.re_err

        in      a,(IO_DATA)     ; has_data flag (0=none, 1=yes)
        or      a
        jr      z,.re_err

        pop     hl              ; buffer ptr
        ; Read 11 bytes: IP[4]+TTL[1]+ID[2]+SEQ[2]+len[2]
        ld      b,11
.re_lp: in      a,(IO_DATA)
        ld      (hl),a
        inc     hl
        djnz    .re_lp

        xor     a               ; ERR_OK
        ei
        ret
.re_err:
        pop     hl
        ld      a,ERR_NO_DATA
        ei
        ret


;--- Function 8: TCPIP_UDP_OPEN
;    Input: HL=local port (0xFFFF=random), B=lifetime (0=transient, 1=resident)
;    Output: A=err, B=handle

FN_UDP_OPEN:
        ld      a,l
        out     (IO_DATA),a     ; port low
        ld      a,h
        out     (IO_DATA),a     ; port high
        ld      a,CMD_UDP_OPEN
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.uo_err
        in      a,(IO_DATA)     ; handle
        or      a
        jr      z,.uo_err
        ld      b,a
        xor     a
        ei
        ret
.uo_err:
        ld      a,ERR_NO_FREE_CONN
        ei
        ret


;--- Function 9: TCPIP_UDP_CLOSE
;    Input: B=handle (0 = close all transient)
;    Output: A=err

FN_UDP_CLOSE:
        ld      a,b
        out     (IO_DATA),a
        ld      a,CMD_UDP_CLOSE
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.uc_err
        in      a,(IO_DATA)
        xor     a
        ei
        ret
.uc_err:
        ld      a,ERR_NO_CONN
        ei
        ret


;--- Function 10: TCPIP_UDP_STATE
;    Input: B=handle
;    Output: A=err, HL=size of first datagram (0 if none)

FN_UDP_STATE:
        ld      a,b
        out     (IO_DATA),a
        ld      a,CMD_UDP_STATE
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ustate_err
        in      a,(IO_DATA)     ; size low
        ld      l,a
        in      a,(IO_DATA)     ; size high
        ld      h,a
        xor     a
        ei
        ret
.ustate_err:
        ld      hl,0
        ld      a,ERR_NO_CONN
        ei
        ret


;--- Function 11: TCPIP_UDP_SEND
;    Input: B=handle, HL=data ptr, DE=parameter block ptr
;      param block: IP[4] + port[2 LE] + size[2 LE]
;    Output: A=err

FN_UDP_SEND:
        ; Save inputs to temporary storage
        ld      (UDP_TMP_HND),a  ; will be overwritten, but save B first
        ld      a,b
        ld      (UDP_TMP_HND),a
        ld      (UDP_TMP_DATA),hl
        ld      (UDP_TMP_PBLK),de

        ; Read param block (8 bytes)
        ld      hl,(UDP_TMP_PBLK)
        ld      a,(hl)
        ld      (UDP_TMP_IP0),a
        inc     hl
        ld      a,(hl)
        ld      (UDP_TMP_IP1),a
        inc     hl
        ld      a,(hl)
        ld      (UDP_TMP_IP2),a
        inc     hl
        ld      a,(hl)
        ld      (UDP_TMP_IP3),a
        inc     hl
        ld      a,(hl)
        ld      (UDP_TMP_PORTL),a
        inc     hl
        ld      a,(hl)
        ld      (UDP_TMP_PORTH),a
        inc     hl
        ld      a,(hl)
        ld      (UDP_TMP_LENL),a
        inc     hl
        ld      a,(hl)
        ld      (UDP_TMP_LENH),a

        ; Write: handle, IP[4], port[2], len[2]
        ld      a,(UDP_TMP_HND)
        out     (IO_DATA),a
        ld      a,(UDP_TMP_IP0)
        out     (IO_DATA),a
        ld      a,(UDP_TMP_IP1)
        out     (IO_DATA),a
        ld      a,(UDP_TMP_IP2)
        out     (IO_DATA),a
        ld      a,(UDP_TMP_IP3)
        out     (IO_DATA),a
        ld      a,(UDP_TMP_PORTL)
        out     (IO_DATA),a
        ld      a,(UDP_TMP_PORTH)
        out     (IO_DATA),a
        ld      a,(UDP_TMP_LENL)
        out     (IO_DATA),a
        ld      a,(UDP_TMP_LENH)
        out     (IO_DATA),a

        ; Write data bytes
        ld      hl,(UDP_TMP_DATA)
        ld      a,(UDP_TMP_LENL)
        ld      c,a
        ld      a,(UDP_TMP_LENH)
        ld      b,a
.usend_d:  ld      a,b
        or      c
        jr      z,.usend_exec
        ld      a,(hl)
        out     (IO_DATA),a
        inc     hl
        dec     bc
        jr      .usend_d

.usend_exec:
        ld      a,CMD_UDP_SEND
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.usend_err
        in      a,(IO_DATA)
        or      a
        jr      nz,.usend_err
        xor     a
        ei
        ret
.usend_err:
        ld      a,ERR_CONN_STATE
        ei
        ret


;--- Function 12: TCPIP_UDP_RCV
;    Input: B=handle, HL=buffer ptr, DE=max size
;    Output: A=err, L.H.E.D=source IP, IX=source port, BC=received size

FN_UDP_RCV:
        ld      (UDP_TMP_DATA),hl   ; save user buffer ptr
        ld      a,b
        out     (IO_DATA),a
        ld      a,e
        out     (IO_DATA),a          ; maxlen low
        ld      a,d
        out     (IO_DATA),a          ; maxlen high
        ld      a,CMD_UDP_RECV
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      STATUS_DATA
        jr      nz,.ur_none

        ; Read srcIP[4] and save to vars
        in      a,(IO_DATA)
        ld      (UDP_TMP_IP0),a
        in      a,(IO_DATA)
        ld      (UDP_TMP_IP1),a
        in      a,(IO_DATA)
        ld      (UDP_TMP_IP2),a
        in      a,(IO_DATA)
        ld      (UDP_TMP_IP3),a
        ; srcPort[2]
        in      a,(IO_DATA)
        ld      (UDP_TMP_PORTL),a
        in      a,(IO_DATA)
        ld      (UDP_TMP_PORTH),a
        ; actual_len[2]
        in      a,(IO_DATA)
        ld      (UDP_TMP_LENL),a
        in      a,(IO_DATA)
        ld      (UDP_TMP_LENH),a

        ; Copy data to user buffer
        ld      hl,(UDP_TMP_DATA)    ; dest
        ld      a,(UDP_TMP_LENL)
        ld      c,a
        ld      a,(UDP_TMP_LENH)
        ld      b,a
.ur_d:  ld      a,b
        or      c
        jr      z,.ur_done
        in      a,(IO_DATA)
        ld      (hl),a
        inc     hl
        dec     bc
        jr      .ur_d

.ur_done:
        ; Set output registers
        ld      a,(UDP_TMP_IP0)
        ld      l,a
        ld      a,(UDP_TMP_IP1)
        ld      h,a
        ld      a,(UDP_TMP_IP2)
        ld      e,a
        ld      a,(UDP_TMP_IP3)
        ld      d,a
        ld      a,(UDP_TMP_PORTL)
        ld      ixl,a
        ld      a,(UDP_TMP_PORTH)
        ld      ixh,a
        ld      a,(UDP_TMP_LENL)
        ld      c,a
        ld      a,(UDP_TMP_LENH)
        ld      b,a
        xor     a
        ei
        ret

.ur_none:
        ld      bc,0
        ld      hl,0
        ld      de,0
        ld      a,ERR_NO_DATA
        ei
        ret


;--- Function 29: TCPIP_WAIT (MANDATORY per UNAPI spec 1.1)
;    Block until next 50/60Hz timer tick, then return ERR_OK.
;    Polls *FC9Eh (JIFFY counter, page 3 always mapped).
;    This gives interrupts time to fire, preventing deadlock
;    in hget's LetTcpipBreathe() polling loop.

FN_WAIT:
        ; Per UNAPI spec: block until next timer interrupt fires.
        ei
        halt
        xor     a
        ret


        ;============================
        ;===  Auxiliary routines  ===
        ;============================

TOUPPER:
        cp      "a"
        ret     c
        cp      "z"+1
        ret     nc
        and     0DFh
        ret


        ;============================
        ;===  UNAPI related data  ===
        ;============================

MY_SLOT:        db      0
MY_SEG:         db      0

; --- Scratch storage for UDP send/recv marshaling ---
UDP_TMP_HND:    db      0
UDP_TMP_IP0:    db      0
UDP_TMP_IP1:    db      0
UDP_TMP_IP2:    db      0
UDP_TMP_IP3:    db      0
UDP_TMP_PORTL:  db      0
UDP_TMP_PORTH:  db      0
UDP_TMP_LENL:   db      0
UDP_TMP_LENH:   db      0
UDP_TMP_DATA:   dw      0
UDP_TMP_PBLK:   dw      0
TCP_INFO_PTR:   dw      0

UNAPI_ID:
        db      "TCP/IP",0
UNAPI_ID_END:

APIINFO:
        db      "openMSX TCP/IP Bridge",0


SEG_CODE_END:
