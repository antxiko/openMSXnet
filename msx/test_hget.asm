;============================================================
; TEST_HGET.ASM — Simula hget paso a paso via UNAPI
; N80 test_hget.asm test_hget.com --direct-output-write
;============================================================

_STROUT: equ    09h
_TERM0:  equ    00h
_CONIN:  equ    01h
EXTBIO:  equ    0FFCAh
ARG:     equ    0F847h

        org     100h

        ;=== 1. Find UNAPI ===
        ld      de,S_FIND
        call    PRINT

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

        ld      de,S_FOUND
        call    PRINT

        ;=== 2. DNS_Q (fn 6) ===
        ld      de,S_DNS
        call    PRINT

        ld      b,0             ; flags
        ld      hl,HOSTNAME     ; hostname (in page 0)
        ld      a,6
        call    CALL_UNAPI
        push    af
        push    bc
        ld      de,S_ERR
        call    PRINT
        pop     bc
        pop     af
        call    PRINTHEX
        ld      de,S_BVAL
        call    PRINT
        ld      a,b
        call    PRINTHEX
        call    NEWLINE
        ; Check if immediate
        ld      a,b
        cp      1
        jr      z,DNS_GOTIP
        cp      2
        jr      z,DNS_GOTIP

        ;=== 2b. DNS_S polling (fn 7) ===
        ld      de,S_POLL
        call    PRINT
DNS_POLL:
        ld      b,0
        ld      a,7
        call    CALL_UNAPI
        or      a
        jp      nz,FAIL
        ld      a,b
        cp      2
        jr      z,DNS_GOTIP
        ld      de,S_DOT
        call    PRINT
        ld      bc,0
.dly:   dec     bc
        ld      a,b
        or      c
        jr      nz,.dly
        jr      DNS_POLL

DNS_GOTIP:
        ; Debug: save regs immediately, print hex
        push    hl
        push    de
        push    bc
        push    af
        ; Print raw L H E D in hex
        ld      a,l
        call    PRINTHEX
        ld      a,h
        call    PRINTHEX
        ld      a,e
        call    PRINTHEX
        ld      a,d
        call    PRINTHEX
        ld      de,S_RAW
        call    PRINT
        pop     af
        pop     bc
        pop     de
        pop     hl

        ld      a,l
        ld      (IP+0),a
        ld      a,h
        ld      (IP+1),a
        ld      a,e
        ld      (IP+2),a
        ld      a,d
        ld      (IP+3),a
        ld      de,S_IP
        call    PRINT
        ld      a,(IP+0)
        call    PRINTDEC
        ld      de,S_DOT
        call    PRINT
        ld      a,(IP+1)
        call    PRINTDEC
        ld      de,S_DOT
        call    PRINT
        ld      a,(IP+2)
        call    PRINTDEC
        ld      de,S_DOT
        call    PRINT
        ld      a,(IP+3)
        call    PRINTDEC
        call    NEWLINE
        call    PRESSKEY

        ;=== 3. TCP_OPEN (fn 13) ===
        ld      de,S_OPEN
        call    PRINT

        ; Build param block
        ld      hl,IP
        ld      de,PBLK
        ld      bc,4
        ldir
        ld      a,80
        ld      (PBLK+4),a     ; port 80 LE
        xor     a
        ld      (PBLK+5),a
        ld      a,0FFh
        ld      (PBLK+6),a     ; local port = random
        ld      (PBLK+7),a
        xor     a
        ld      (PBLK+8),a     ; timeout
        ld      (PBLK+9),a
        ld      (PBLK+10),a    ; flags: active, transient

        ld      hl,PBLK
        ld      a,13
        call    CALL_UNAPI
        push    af
        ld      de,S_ERR
        call    PRINT
        pop     af
        push    af
        call    PRINTHEX
        ld      de,S_HNDL
        call    PRINT
        ld      a,b
        ld      (HANDLE),a
        call    PRINTHEX
        call    NEWLINE
        pop     af
        or      a
        jp      nz,FAIL

        ;=== 4. Wait ESTABLISHED (fn 16) ===
        ld      de,S_WAITEST
        call    PRINT
TCP_POLL:
        ld      a,(HANDLE)
        ld      b,a
        ld      hl,0
        ld      a,16
        call    CALL_UNAPI
        or      a
        jp      nz,FAIL
        ld      a,b
        cp      4
        jr      z,TCP_EST
        cp      0
        jp      z,TCP_DEAD
        call    PRINTHEX
        ld      de,S_DOT
        call    PRINT
        ld      bc,0
.dly2:  dec     bc
        ld      a,b
        or      c
        jr      nz,.dly2
        jr      TCP_POLL

TCP_EST:
        ld      de,S_ESTAB
        call    PRINT
        call    PRESSKEY

        ;=== 5. TCP_SEND (fn 17) ===
        ld      de,S_SEND
        call    PRINT

        ld      a,(HANDLE)
        ld      b,a
        ld      de,HTTP_REQ
        ld      hl,HTTP_REQ_END-HTTP_REQ
        ld      c,0
        ld      a,17
        call    CALL_UNAPI
        ld      de,S_ERR
        call    PRINT
        call    PRINTHEX
        call    NEWLINE
        call    PRESSKEY

        ;=== 6. TCP_RECV (fn 18) ===
        ld      de,S_RECV
        call    PRINT
        ld      b,30
RECV_LP:
        push    bc
        ld      a,(HANDLE)
        ld      b,a
        ld      de,RBUF
        ld      hl,200
        ld      a,18
        call    CALL_UNAPI
        or      a
        jr      nz,RECV_ERR
        ld      a,b
        or      c
        jr      z,RECV_EMPTY

        ; Got data
        push    bc
        ld      a,b
        call    PRINTHEX
        ld      a,c
        call    PRINTHEX
        ld      de,S_BYTES
        call    PRINT
        pop     bc

        ; Print first chars
        ld      hl,RBUF
        ld      a,c
        cp      60
        jr      c,.ok
        ld      c,60
.ok:    ld      b,c
.plp:   ld      a,(hl)
        cp      32
        jr      c,.sk
        cp      127
        jr      nc,.sk
        ld      e,a
        push    bc
        push    hl
        ld      c,02h
        call    5
        pop     hl
        pop     bc
.sk:    inc     hl
        djnz    .plp
        call    NEWLINE

        pop     bc
        jr      RECV_DONE

RECV_EMPTY:
        pop     bc
        ld      de,S_DOT
        call    PRINT
        push    bc
        ld      bc,0
.dly3:  dec     bc
        ld      a,b
        or      c
        jr      nz,.dly3
        pop     bc
        djnz    RECV_LP
        ld      de,S_NODATA
        call    PRINT
        jr      RECV_DONE

RECV_ERR:
        pop     bc
        ld      de,S_RECVERR
        call    PRINT
        call    PRINTHEX
        call    NEWLINE

RECV_DONE:
        ; Close
        ld      a,(HANDLE)
        ld      b,a
        ld      a,14
        call    CALL_UNAPI
        jr      DONE

TCP_DEAD:
        ld      de,S_DEAD
        call    PRINT
        jr      DONE

FAIL:
        ld      de,S_FAIL
        call    PRINT

DONE:
        ld      de,S_DONE
        call    PRINT
        ld      c,_TERM0
        jp      5

NOIMPL:
        ld      de,S_NOIMPL
        call    PRINT
        jr      DONE


;=== CALL_UNAPI ===
; Call UNAPI function via RAM helper
; Input: A=fn, BC/DE/HL=params
; Output: all regs as returned by function
;
; The helper at (HELPER) is a JP to the segment call routine.
; We do: CALL JP_HL with HL=helper, after setting IY=slot:seg, IX=entry
; "CALL JP_HL" pushes return addr, then JP (HL) jumps to helper.
; Helper switches segment, calls IX, restores, and RETs to us.

CALL_UNAPI:
        ; Save fn and params
        ld      (.fn),a
        ld      (.sav_bc),bc
        ld      (.sav_de),de
        ld      (.sav_hl),hl

        ; Setup IY=slot:seg, IX=entry
        ld      a,(SLOT)
        ld      iyh,a
        ld      a,(SEG_N)
        ld      iyl,a
        ld      ix,(ENTRY)

        ; Store helper address for the trampoline
        ld      hl,(HELPER)
        ld      (.helper_jp+1),hl

        ; Restore all params
        ld      a,(.fn)
        ld      bc,(.sav_bc)
        ld      de,(.sav_de)
        ld      hl,(.sav_hl)

        ; CALL the helper (which does segment switch + CALL IX + return)
        call    .helper_jp
        ret

.helper_jp:
        jp      0               ; patched with helper address

.fn:    db      0
.sav_bc: dw     0
.sav_de: dw     0
.sav_hl: dw     0


;=== Utilities ===

PRINT:  ld      c,_STROUT
        call    5
        ret

NEWLINE:
        ld      de,S_NL
        jr      PRINT

PRESSKEY:
        ld      de,S_KEY
        call    PRINT
        ld      c,_CONIN
        call    5
        call    NEWLINE
        ret

PRINTHEX:
        push    af
        rrca
        rrca
        rrca
        rrca
        and     0Fh
        call    .nib
        pop     af
        and     0Fh
.nib:   cp      10
        jr      c,.dig
        add     a,'A'-10
        jr      .out
.dig:   add     a,'0'
.out:   ld      e,a
        push    bc
        push    hl
        ld      c,02h
        call    5
        pop     hl
        pop     bc
        ret

PRINTDEC:
        push    bc
        push    de
        ld      c,0
        ld      b,100
        call    .dd
        ld      b,10
        call    .dd
        add     a,'0'
        ld      e,a
        push    hl
        ld      c,02h
        call    5
        pop     hl
        pop     de
        pop     bc
        ret
.dd:    ld      d,0
.ddl:   cp      b
        jr      c,.ddd
        sub     b
        inc     d
        jr      .ddl
.ddd:   push    af
        ld      a,d
        or      a
        jr      z,.dds
        ld      c,1
.dds:   ld      a,c
        or      a
        jr      z,.ddn
        ld      a,d
        add     a,'0'
        ld      e,a
        push    bc
        push    hl
        ld      c,02h
        call    5
        pop     hl
        pop     bc
.ddn:   pop     af
        ret


;=== Data ===

SLOT:   db      0
SEG_N:  db      0
ENTRY:  dw      0
HELPER: dw      0
HANDLE: db      0
IP:     db      0,0,0,0

; Param block for TCP_OPEN (11 bytes) — in page 0 (< 4000h)
PBLK:   ds      11

STR_TCPIP: db   "TCP/IP",0

HOSTNAME: db    "example.com",0

HTTP_REQ:
        db      "GET / HTTP/1.0",13,10
        db      "Host: example.com",13,10
        db      13,10
HTTP_REQ_END:

; Receive buffer — must be outside page 1
RBUF:   ds      256

;=== Strings ===

S_NL:   db      13,10,"$"
S_DOT:  db      ".$"
S_KEY:  db      " [PRESS KEY]$"
S_FIND: db      "Finding UNAPI TCP/IP...$"
S_FOUND: db     "OK",13,10,"$"
S_NOIMPL: db    "NOT FOUND!",13,10,"$"
S_DNS:  db      "DNS resolve example.com...$"
S_ERR:  db      " err=$"
S_BVAL: db      " B=$"
S_POLL: db      "Polling$"
S_IP:   db      "IP: $"
S_OPEN: db      "TCP_OPEN port 80...$"
S_HNDL: db      " handle=$"
S_WAITEST: db   "Waiting ESTABLISHED...$"
S_ESTAB: db     "ESTABLISHED!",13,10,"$"
S_SEND: db      "TCP_SEND HTTP GET...$"
S_RECV: db      "TCP_RECV...$"
S_BYTES: db     "h bytes$"
S_NODATA: db    "No data!",13,10,"$"
S_RECVERR: db   "RECV err=$"
S_DEAD: db      "Connection CLOSED",13,10,"$"
S_FAIL: db      "FAILED",13,10,"$"
S_RAW:  db      "h=LHED raw",13,10,"$"
S_DONE: db      13,10,"Done.",13,10,"$"
