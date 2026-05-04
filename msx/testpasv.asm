; TESTPASV.ASM — Mini TCP server using UNAPI passive mode
; Listens on port 7777, accepts one connection, sends "Hello from MSX\r\n",
; closes, terminates.
;
; Assemble: N80 testpasv.asm testpasv.com --direct-output-write

_STROUT: equ    09h
_TERM0:  equ    00h
_CONIN:  equ    01h
EXTBIO:  equ    0FFCAh
ARG:     equ    0F847h

        org     100h

        ;=== Find UNAPI TCP/IP ===
        ld      hl,STR_TCPIP
        ld      de,ARG
        ld      bc,7
        ldir

        ld      de,2222h
        xor     a
        ld      b,0
        call    EXTBIO
        ld      a,b
        or      a
        jp      z,NOIMPL

        ld      de,2222h
        ld      a,1
        call    EXTBIO
        ld      (SLOT),a
        ld      a,b
        ld      (SEG_N),a
        ld      (ENTRY),hl

        ld      de,2222h
        ld      hl,0
        ld      a,0FFh
        call    EXTBIO
        ld      (HELPER),hl

        ld      de,S_LISTEN
        call    PRINT

        ;=== TCP_OPEN passive on port 7777 ===
        ; Build 11-byte param block at PBLK
        ; +0..+3: IP = 0.0.0.0 (accept any)
        xor     a
        ld      (PBLK+0),a
        ld      (PBLK+1),a
        ld      (PBLK+2),a
        ld      (PBLK+3),a
        ; +4..+5: remote port (ignored for passive)
        ld      (PBLK+4),a
        ld      (PBLK+5),a
        ; +6..+7: local port = 7777 (0x1E61) LE
        ld      a,061h
        ld      (PBLK+6),a
        ld      a,01Eh
        ld      (PBLK+7),a
        ; +8..+9: timeout
        xor     a
        ld      (PBLK+8),a
        ld      (PBLK+9),a
        ; +10: flags = 1 (passive, transient)
        ld      a,1
        ld      (PBLK+10),a

        ld      hl,PBLK
        ld      a,13            ; TCPIP_TCP_OPEN
        call    CALL_UNAPI
        or      a
        jp      nz,OPEN_FAIL

        ld      a,b
        ld      (HANDLE),a

        ld      de,S_LISTENING
        call    PRINT

        ;=== Poll TCP_STATE until ESTABLISHED ===
WAIT_CONN:
        ld      a,(HANDLE)
        ld      b,a
        ld      hl,0
        ld      a,16            ; TCPIP_TCP_STATE
        call    CALL_UNAPI
        or      a
        jr      nz,STATE_ERR
        ld      a,b
        cp      4               ; ESTABLISHED?
        jr      z,GOT_CONN
        ; Still listening, wait
        ld      a,29            ; TCPIP_WAIT
        call    CALL_UNAPI
        jr      WAIT_CONN

GOT_CONN:
        ld      de,S_GOT
        call    PRINT

        ;=== TCP_SEND "Hello from MSX\r\n" ===
        ld      a,(HANDLE)
        ld      b,a
        ld      de,MSG
        ld      hl,MSG_END-MSG
        ld      c,0
        ld      a,17            ; TCPIP_TCP_SEND
        call    CALL_UNAPI

        ;=== Short delay then close ===
        ld      a,29
        call    CALL_UNAPI
        ld      a,29
        call    CALL_UNAPI

        ld      a,(HANDLE)
        ld      b,a
        ld      a,14            ; TCPIP_TCP_CLOSE
        call    CALL_UNAPI

        ld      de,S_DONE
        call    PRINT
        jp      DONE

OPEN_FAIL:
        ld      de,S_OPENFAIL
        call    PRINT
        jp      DONE
STATE_ERR:
        ld      de,S_STATEFAIL
        call    PRINT
        jp      DONE
NOIMPL:
        ld      de,S_NOIMPL
        call    PRINT
DONE:
        ld      c,_TERM0
        jp      5


;=== CALL_UNAPI ===

CALL_UNAPI:
        ld      (.fn),a
        ld      (.sav_bc),bc
        ld      (.sav_de),de
        ld      (.sav_hl),hl

        ld      a,(SLOT)
        ld      iyh,a
        ld      a,(SEG_N)
        ld      iyl,a
        ld      ix,(ENTRY)

        ld      hl,(HELPER)
        ld      (.helper_jp+1),hl

        ld      a,(.fn)
        ld      bc,(.sav_bc)
        ld      de,(.sav_de)
        ld      hl,(.sav_hl)

        call    .helper_jp
        ret

.helper_jp:
        jp      0

.fn:    db      0
.sav_bc: dw     0
.sav_de: dw     0
.sav_hl: dw     0


PRINT:  ld      c,_STROUT
        call    5
        ret


;=== Data ===

SLOT:    db     0
SEG_N:   db     0
ENTRY:   dw     0
HELPER:  dw     0
HANDLE:  db     0

PBLK:    ds     11

STR_TCPIP: db   "TCP/IP",0

MSG:     db     "Hello from MSX!",13,10
MSG_END:

S_LISTEN:    db "Opening TCP server on port 7777...",13,10,"$"
S_LISTENING: db "Listening (connect with: telnet <IP> 7777)",13,10,"$"
S_GOT:       db "Incoming connection accepted!",13,10,"$"
S_DONE:      db "Sent message, closed.",13,10,"$"
S_OPENFAIL:  db "TCP_OPEN failed",13,10,"$"
S_STATEFAIL: db "TCP_STATE error",13,10,"$"
S_NOIMPL:    db "No UNAPI TCP/IP found",13,10,"$"
