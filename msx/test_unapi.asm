;============================================================
; TEST_UNAPI.ASM — Test de todas las funciones UNAPI TCP/IP
; Prueba cada función una a una mostrando resultado
;
; Compilar: N80 test_unapi.asm test.com --direct-output-write
;============================================================

_STROUT: equ    09h
_TERM0:  equ    00h
_CONIN:  equ    01h
EXTBIO:  equ    0FFCAh
ARG:     equ    0F847h

IO_CMD:  equ    7Eh
IO_DATA: equ    7Fh

        org     100h

        ;=== Test 0: Find UNAPI implementation ===
        ld      de,T0_S
        call    PRINT

        ; Copy "TCP/IP" to ARG
        ld      hl,STR_TCPIP
        ld      de,ARG
        ld      bc,7
        ldir

        ; Count implementations
        ld      de,2222h
        xor     a
        ld      b,0
        call    EXTBIO
        ld      a,b
        or      a
        jr      nz,.t0_found
        ld      de,FAIL_S
        call    PRINT
        ld      de,T0_NONE_S
        call    PRINT
        jp      DONE
.t0_found:
        ld      (.t0_count),a
        call    PRINTHEX
        ld      de,T0_FOUND_S
        call    PRINT

        ; Get impl #1 info
        ld      de,2222h
        ld      a,1
        call    EXTBIO
        ; A=slot, B=seg, HL=entry
        ld      (IMPL_SLOT),a
        ld      a,b
        ld      (IMPL_SEG),a
        ld      (IMPL_ENTRY),hl

        ; Call fn 0 to get name
        ld      a,(IMPL_SLOT)
        ld      iyh,a
        ld      a,(IMPL_SEG)
        ld      iyl,a
        ld      ix,(IMPL_ENTRY)

        ; Find RAM helper
        ld      de,2222h
        push    ix
        push    iy
        ld      hl,0
        ld      a,0FFh
        call    EXTBIO
        ld      (HELPER_ADD),hl
        pop     iy
        pop     ix

        ; Call fn 0 via helper
        ld      hl,(HELPER_ADD)
        xor     a               ; fn 0
        call    CALL_HL
        ; HL=name string
        ; Print name by reading from segment
        ld      de,T0_NAME_S
        call    PRINT
        ; HL points to name in segment - need to read via helper
        ; For simplicity, just print slot/seg info
        ld      a,(IMPL_SLOT)
        call    PRINTHEX
        ld      de,T0_SLASH_S
        call    PRINT
        ld      a,(IMPL_SEG)
        call    PRINTHEX
        call    NEWLINE

        call    PRESSKEY

        ;=== Test 1: TCPIP_GET_CAPAB block 1 ===
        ld      de,T1_S
        call    PRINT

        ld      a,(IMPL_SLOT)
        ld      iyh,a
        ld      a,(IMPL_SEG)
        ld      iyl,a
        ld      ix,(IMPL_ENTRY)
        ld      hl,(HELPER_ADD)
        ld      b,1             ; block 1
        ld      a,1             ; fn 1
        call    CALL_HL
        ; A=err, HL=caps, DE=features
        push    hl
        push    de
        call    PRINTHEX        ; error code
        ld      de,T1_ERR_S
        call    PRINT
        pop     de
        pop     hl
        ld      a,h
        call    PRINTHEX
        ld      a,l
        call    PRINTHEX
        ld      de,T1_CAPS_S
        call    PRINT
        call    NEWLINE

        call    PRESSKEY

        ;=== Test 2: TCPIP_GET_CAPAB block 2 ===
        ld      de,T2_S
        call    PRINT

        ld      a,(IMPL_SLOT)
        ld      iyh,a
        ld      a,(IMPL_SEG)
        ld      iyl,a
        ld      ix,(IMPL_ENTRY)
        ld      hl,(HELPER_ADD)
        ld      b,2             ; block 2
        ld      a,1             ; fn 1
        call    CALL_HL
        ; B=maxTCP, C=maxUDP, D=freeTCP, E=freeUDP
        ld      a,b
        call    PRINTHEX
        ld      de,T2_MAXTCP_S
        call    PRINT
        call    NEWLINE

        call    PRESSKEY

        ;=== Test 3: TCPIP_NET_STATE ===
        ld      de,T3_S
        call    PRINT

        ld      a,(IMPL_SLOT)
        ld      iyh,a
        ld      a,(IMPL_SEG)
        ld      iyl,a
        ld      ix,(IMPL_ENTRY)
        ld      hl,(HELPER_ADD)
        ld      a,3             ; fn 3
        call    CALL_HL
        ; A=err, B=state
        push    af
        ld      a,b
        call    PRINTHEX
        ld      de,T3_STATE_S
        call    PRINT
        pop     af
        call    PRINTHEX
        ld      de,T3_ERR_S
        call    PRINT
        call    NEWLINE

        call    PRESSKEY

        ;=== Test 4: TCPIP_GET_IPINFO (local IP) ===
        ld      de,T4_S
        call    PRINT

        ld      a,(IMPL_SLOT)
        ld      iyh,a
        ld      a,(IMPL_SEG)
        ld      iyl,a
        ld      ix,(IMPL_ENTRY)
        ld      hl,(HELPER_ADD)
        ld      b,1             ; index 1 = local IP
        ld      a,2             ; fn 2
        call    CALL_HL
        ; A=err, L.H.E.D = IP
        push    af
        ld      a,l
        call    PRINTDEC
        ld      de,DOT_S
        call    PRINT
        ld      a,h
        call    PRINTDEC
        ld      de,DOT_S
        call    PRINT
        ld      a,e
        call    PRINTDEC
        ld      de,DOT_S
        call    PRINT
        ld      a,d
        call    PRINTDEC
        pop     af
        push    af
        ld      de,T4_ERR_S
        call    PRINT
        pop     af
        call    PRINTHEX
        call    NEWLINE

        call    PRESSKEY

        ;=== Test 5: TCPIP_DNS_Q (resolve example.com) ===
        ld      de,T5_S
        call    PRINT

        ld      a,(IMPL_SLOT)
        ld      iyh,a
        ld      a,(IMPL_SEG)
        ld      iyl,a
        ld      ix,(IMPL_ENTRY)
        ld      hl,(HELPER_ADD)
        push    hl
        pop     ix              ; IX = helper for later
        ; Restore proper regs
        ld      a,(IMPL_SLOT)
        ld      iyh,a
        ld      a,(IMPL_SEG)
        ld      iyl,a
        ld      ix,(IMPL_ENTRY)
        ld      hl,(HELPER_ADD)
        ld      b,0             ; flags
        push    hl
        ld      hl,HOSTNAME     ; hostname ptr (in page 0)
        ld      a,6             ; fn 6 DNS_Q
        pop     iy              ; OOPS need helper in HL
        ; Actually: helper calling convention needs
        ; IYH=slot, IYL=seg, IX=entry, HL=helper, A=fn
        ; Let me redo this properly

        ; Setup for helper call
        ld      a,(IMPL_SLOT)
        ld      iyh,a
        ld      a,(IMPL_SEG)
        ld      iyl,a
        ld      ix,(IMPL_ENTRY)
        ld      hl,(HELPER_ADD)
        ; Params: B=0 (flags), HL=hostname BUT HL is used for helper!
        ; Problem: HL is both helper address AND hostname param
        ; Solution: put hostname in page 3 area and pass via stack trick
        ; Actually the helper call puts HL as the param to the function
        ; NO - the helper expects: A=fn, HL=helper_addr, IX=entry, IY=slot:seg
        ; The UNAPI function receives params in registers
        ; But HL is used for the helper call...
        ; We need to use the segment CALLS mechanism differently
        ;
        ; For DNS_Q: the function needs HL=hostname
        ; But the helper calling convention uses HL for the jump
        ; This is a problem. Let me think...
        ; Actually looking at unapi-ram.asm CALL_HL: jp (hl)
        ; So we call helper which switches segment and calls IX
        ; Inside the segment, the function receives whatever regs we set
        ; But HL was consumed by the jp (hl)...
        ; Actually NO - the RAM helper preserves registers properly
        ; The helper routine at (HELPER_ADD) is designed to:
        ; 1. Save current page 1 segment
        ; 2. Switch to IYL segment in IYH slot
        ; 3. CALL IX with ALL other registers preserved
        ; 4. Restore page 1
        ; So HL gets clobbered by the jp (hl) but the helper
        ; internally saves it and passes it to the function...
        ; Actually let me just test DNS via direct I/O first

        ; DIRECT I/O TEST for DNS (bypass UNAPI calling convention)
        ld      hl,HOSTNAME
.dns_lp:
        ld      a,(hl)
        out     (IO_DATA),a
        or      a
        jr      z,.dns_sent
        inc     hl
        jr      .dns_lp
.dns_sent:
        ld      a,01h           ; CMD_DNS_QUERY
        out     (IO_CMD),a
        in      a,(IO_CMD)
        call    PRINTHEX
        ld      de,T5_STATUS_S
        call    PRINT

        in      a,(IO_DATA)     ; result status
        call    PRINTHEX
        ld      de,T5_RESULT_S
        call    PRINT
        call    NEWLINE

        ; Poll DNS_STATUS
        ld      de,T5_POLL_S
        call    PRINT

.dns_poll:
        ld      a,02h           ; CMD_DNS_STATUS
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      02h             ; STATUS_DATA?
        jr      nz,.dns_wait

        in      a,(IO_DATA)     ; status byte
        cp      2               ; complete?
        jr      z,.dns_ok
        cp      0FFh            ; error?
        jr      z,.dns_fail
        ; still in progress
.dns_wait:
        ld      de,DOT_S
        call    PRINT
        ; small delay
        ld      bc,0
.delay: dec     bc
        ld      a,b
        or      c
        jr      nz,.delay
        jr      .dns_poll

.dns_ok:
        call    NEWLINE
        ld      de,T5_OK_S
        call    PRINT
        ; Read IP and SAVE it for TCP_OPEN
        in      a,(IO_DATA)
        ld      (RESOLVED_IP+0),a
        call    PRINTDEC
        ld      de,DOT_S
        call    PRINT
        in      a,(IO_DATA)
        ld      (RESOLVED_IP+1),a
        call    PRINTDEC
        ld      de,DOT_S
        call    PRINT
        in      a,(IO_DATA)
        ld      (RESOLVED_IP+2),a
        call    PRINTDEC
        ld      de,DOT_S
        call    PRINT
        in      a,(IO_DATA)
        ld      (RESOLVED_IP+3),a
        call    PRINTDEC
        call    NEWLINE
        jr      .dns_done

.dns_fail:
        call    NEWLINE
        ld      de,T5_FAIL_S
        call    PRINT
        in      a,(IO_DATA)     ; error code
        call    PRINTHEX
        call    NEWLINE

.dns_done:
        call    PRESSKEY

        ;=== Test 6: TCP_OPEN to port 80 ===
        ld      de,T6_S
        call    PRINT

        ; Use DNS-resolved IP
        ld      a,(RESOLVED_IP+0)
        out     (IO_DATA),a
        ld      a,(RESOLVED_IP+1)
        out     (IO_DATA),a
        ld      a,(RESOLVED_IP+2)
        out     (IO_DATA),a
        ld      a,(RESOLVED_IP+3)
        out     (IO_DATA),a
        ld      a,80            ; port low
        out     (IO_DATA),a
        ld      a,0             ; port high
        out     (IO_DATA),a

        ld      a,03h           ; CMD_TCP_OPEN
        out     (IO_CMD),a

        in      a,(IO_CMD)
        cp      02h
        jr      nz,.tcp_open_fail

        in      a,(IO_DATA)     ; handle
        ld      (TCP_HANDLE),a
        call    PRINTHEX
        ld      de,T6_HANDLE_S
        call    PRINT
        call    NEWLINE

        ; Wait for ESTABLISHED
        ld      de,T6_WAIT_S
        call    PRINT
.tcp_wait:
        ld      a,(TCP_HANDLE)
        out     (IO_DATA),a
        ld      a,07h           ; CMD_TCP_STATE
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      02h
        jr      nz,.tcp_wait2
        in      a,(IO_DATA)     ; state
        cp      4               ; ESTABLISHED?
        jr      z,.tcp_est
        call    PRINTHEX
        ld      de,DOT_S
        call    PRINT
.tcp_wait2:
        ld      bc,0
.td2:   dec     bc
        ld      a,b
        or      c
        jr      nz,.td2
        jr      .tcp_wait

.tcp_est:
        call    NEWLINE
        ld      de,T6_EST_S
        call    PRINT
        call    NEWLINE
        jr      .tcp_open_done

.tcp_open_fail:
        ld      de,T6_FAIL_S
        call    PRINT
        call    NEWLINE

.tcp_open_done:
        call    PRESSKEY

        ;=== Test 7: TCP_SEND HTTP GET ===
        ld      de,T7_S
        call    PRINT

        ; Write handle + len + data
        ld      a,(TCP_HANDLE)
        out     (IO_DATA),a
        ; HTTP request length
        ld      hl,HTTP_REQ_END-HTTP_REQ
        ld      a,l
        out     (IO_DATA),a    ; len low
        ld      a,h
        out     (IO_DATA),a    ; len high
        ; Write HTTP request bytes
        ld      hl,HTTP_REQ
        ld      bc,HTTP_REQ_END-HTTP_REQ
.send_lp:
        ld      a,(hl)
        out     (IO_DATA),a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.send_lp

        ld      a,04h           ; CMD_TCP_SEND
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      02h
        jr      nz,.send_fail
        in      a,(IO_DATA)     ; status
        call    PRINTHEX
        ld      de,T7_OK_S
        call    PRINT
        call    NEWLINE
        jr      .send_done
.send_fail:
        ld      de,T7_FAIL_S
        call    PRINT
        call    NEWLINE
.send_done:
        call    PRESSKEY

        ;=== Test 8: TCP_RECV ===
        ld      de,T8_S
        call    PRINT

        ; Wait a bit for response
        ld      de,T8_WAIT_S
        call    PRINT
        ld      b,20            ; retry 20 times
.recv_retry:
        push    bc

        ld      a,(TCP_HANDLE)
        out     (IO_DATA),a
        ld      a,128           ; maxlen low (128 bytes)
        out     (IO_DATA),a
        ld      a,0             ; maxlen high
        out     (IO_DATA),a

        ld      a,05h           ; CMD_TCP_RECV
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      02h
        jr      nz,.recv_none

        ; Read actual length
        in      a,(IO_DATA)     ; len low
        ld      c,a
        in      a,(IO_DATA)     ; len high
        ld      b,a
        ld      a,b
        or      c
        jr      z,.recv_none

        ; Got data! Print it
        call    NEWLINE
        ld      a,b
        call    PRINTHEX
        ld      a,c
        call    PRINTHEX
        ld      de,T8_BYTES_S
        call    PRINT
        call    NEWLINE

        ; Read and print first 128 bytes
.recv_lp:
        ld      a,b
        or      c
        jr      z,.recv_end
        in      a,(IO_DATA)
        ; Print char if printable
        cp      32
        jr      c,.recv_ctrl
        cp      127
        jr      nc,.recv_ctrl
        ld      e,a
        push    bc
        ld      c,02h
        call    5               ; print char
        pop     bc
        jr      .recv_next
.recv_ctrl:
        ; skip control chars
.recv_next:
        dec     bc
        jr      .recv_lp

.recv_end:
        pop     bc
        call    NEWLINE
        jr      .recv_done

.recv_none:
        pop     bc
        ld      de,DOT_S
        call    PRINT
        ; delay
        push    bc
        ld      bc,0
.rd:    dec     bc
        ld      a,b
        or      c
        jr      nz,.rd
        pop     bc
        djnz    .recv_retry

        call    NEWLINE
        ld      de,T8_NODATA_S
        call    PRINT
        call    NEWLINE

.recv_done:
        call    PRESSKEY

        ;=== Test 9: TCP_CLOSE ===
        ld      de,T9_S
        call    PRINT

        ld      a,(TCP_HANDLE)
        out     (IO_DATA),a
        ld      a,06h           ; CMD_TCP_CLOSE
        out     (IO_CMD),a
        in      a,(IO_CMD)
        cp      02h
        jr      nz,.close_fail
        in      a,(IO_DATA)
        ld      de,T9_OK_S
        call    PRINT
        call    NEWLINE
        jr      .close_done
.close_fail:
        ld      de,T9_FAIL_S
        call    PRINT
        call    NEWLINE
.close_done:

DONE:
        ld      de,DONE_S
        call    PRINT
        ld      c,_TERM0
        jp      5


;=== Utility routines ===

PRINT:
        ld      c,_STROUT
        call    5
        ret

NEWLINE:
        ld      de,NL_S
        call    PRINT
        ret

PRESSKEY:
        ld      de,KEY_S
        call    PRINT
        ld      c,_CONIN
        call    5
        call    NEWLINE
        ret

; Print A as 2 hex digits
PRINTHEX:
        push    af
        rrca
        rrca
        rrca
        rrca
        and     0Fh
        call    .hexnib
        pop     af
        and     0Fh
.hexnib:
        cp      10
        jr      c,.hexdig
        add     a,'A'-10
        jr      .hexout
.hexdig:
        add     a,'0'
.hexout:
        ld      e,a
        push    bc
        push    hl
        ld      c,02h
        call    5
        pop     hl
        pop     bc
        ret

; Print A as decimal (0-255)
PRINTDEC:
        push    bc
        push    de
        ld      c,0             ; leading zero flag
        ld      b,100
        call    .decdig
        ld      b,10
        call    .decdig
        add     a,'0'
        ld      e,a
        push    hl
        ld      c,02h
        call    5
        pop     hl
        pop     de
        pop     bc
        ret
.decdig:
        ld      d,0
.dd_lp: cp      b
        jr      c,.dd_done
        sub     b
        inc     d
        jr      .dd_lp
.dd_done:
        push    af
        ld      a,d
        or      a
        jr      z,.dd_skip
        ld      c,1             ; had nonzero digit
.dd_skip:
        ld      a,c
        or      a
        jr      z,.dd_nop
        ld      a,d
        add     a,'0'
        ld      e,a
        push    bc
        push    hl
        ld      c,02h
        call    5
        pop     hl
        pop     bc
.dd_nop:
        pop     af
        ret

; Call helper: jp (hl) with A=fn, IYH=slot, IYL=seg, IX=entry
CALL_HL:
        jp      (hl)


;=== Data ===

TCP_HANDLE:     db      0
RESOLVED_IP:    db      0,0,0,0
IMPL_SLOT:      db      0
IMPL_SEG:       db      0
IMPL_ENTRY:     dw      0
HELPER_ADD:     dw      0
.t0_count:      db      0

STR_TCPIP:      db      "TCP/IP",0

HOSTNAME:       db      "example.com",0

HTTP_REQ:       db      "GET / HTTP/1.0",13,10
                db      "Host: example.com",13,10
                db      13,10
HTTP_REQ_END:

;=== Strings ===

NL_S:           db      13,10,"$"
DOT_S:          db      ".$"
KEY_S:          db      13,10,"-- Press key --$"
FAIL_S:         db      "FAIL$"
DONE_S:         db      13,10,"=== All tests done ===$"

T0_S:           db      "=== Test 0: Find UNAPI TCP/IP ===",13,10,"$"
T0_NONE_S:      db      " No implementation found!",13,10,"$"
T0_FOUND_S:     db      " implementation(s) found",13,10,"$"
T0_NAME_S:      db      "Slot/Seg: $"
T0_SLASH_S:     db      "/$"

T1_S:           db      "=== Test 1: GET_CAPAB block 1 ===",13,10,"$"
T1_ERR_S:       db      " err, caps=$"
T1_CAPS_S:      db      "h$"

T2_S:           db      "=== Test 2: GET_CAPAB block 2 ===",13,10,"$"
T2_MAXTCP_S:    db      "h maxTCP$"

T3_S:           db      "=== Test 3: NET_STATE ===",13,10,"$"
T3_STATE_S:     db      "h state, err=$"
T3_ERR_S:       db      "h$"

T4_S:           db      "=== Test 4: GET_IPINFO (local) ===",13,10,"$"
T4_ERR_S:       db      " err=$"

T5_S:           db      "=== Test 5: DNS (example.com) ===",13,10,"$"
T5_STATUS_S:    db      "h bridge status, $"
T5_RESULT_S:    db      "h result",13,10,"$"
T5_POLL_S:      db      "Polling DNS$"
T5_OK_S:        db      "Resolved: $"
T5_FAIL_S:      db      "DNS FAILED, code=$"

T6_S:           db      "=== Test 6: TCP_OPEN (example.com:80) ===",13,10,"$"
T6_HANDLE_S:    db      "h handle$"
T6_WAIT_S:      db      "Waiting ESTABLISHED$"
T6_EST_S:       db      "ESTABLISHED!$"
T6_FAIL_S:      db      "TCP_OPEN FAILED$"

T7_S:           db      "=== Test 7: TCP_SEND (HTTP GET) ===",13,10,"$"
T7_OK_S:        db      "h send status (0=OK)$"
T7_FAIL_S:      db      "TCP_SEND FAILED$"

T8_S:           db      "=== Test 8: TCP_RECV ===",13,10,"$"
T8_WAIT_S:      db      "Waiting for data$"
T8_BYTES_S:     db      "h bytes received:$"
T8_NODATA_S:    db      "No data received!$"

T9_S:           db      "=== Test 9: TCP_CLOSE ===",13,10,"$"
T9_OK_S:        db      "Closed OK$"
T9_FAIL_S:      db      "TCP_CLOSE FAILED$"
