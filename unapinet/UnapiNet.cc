// Incluir Socket.hh ANTES del header propio para que SOCKET
// esté definido. Usamos un truco: undefine la macro "interface"
// que windows.h define y que rompe otros headers de openMSX.
#include "Socket.hh"
#ifdef _WIN32
#include <ws2tcpip.h>
#ifdef interface
#undef interface
#endif
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#endif

#include "UnapiNet.hh"
#include "serialize.hh"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstring>

// Helper para convertir entre intptr_t (header) y SOCKET (socket API)
#define SOCK(x) static_cast<SOCKET>(x)
#define ISOCK(x) static_cast<intptr_t>(x)

// ============================================================
//  UnapiNet  –  openMSX Extension  (Phase 2)
//
//  Bridge entre puertos I/O del MSX y sockets BSD del host.
//  Soporta: DNS asíncrono, TCP (hasta 4 conexiones simultáneas),
//  buffer circular de recepción con hilo background.
// ============================================================

// --- Capabilities para QUERY_CAP (Phase 2) ---
// Byte 0: bit0=TCP bit1=UDP bit2=DNS  → 0x07 = TCP+UDP+DNS
// Byte 1: versión bridge = 0x03 (Phase 3 - UDP added)
static constexpr uint8_t CAP_BYTE0 = 0x07; // TCP + UDP + DNS
static constexpr uint8_t CAP_BYTE1 = 0x03; // bridge version 3

// Tamaño máximo de transferencia por comando TCP_SEND/TCP_RECV
static constexpr size_t MAX_TRANSFER = 4096;

// Tamaño máximo del buffer de recepción por conexión
// BBS ANSI screens can be 16-32KB, needs big buffer
static constexpr size_t MAX_RECV_BUF = 65536;

namespace openmsx {

// Activación de sockets RAII (WSAStartup en Windows).
// Variable estática: se inicializa la primera vez que se crea un UnapiNet.
static SocketActivator socketActivator;

// ============================================================
//  Constructor / Destructor
// ============================================================

UnapiNet::UnapiNet(const DeviceConfig& config)
    : MSXDevice(config)
    , state(State::IDLE)
    , statusReg(STATUS_OK)
    , resultPos(0)
{
    paramBuf.reserve(MAX_TRANSFER + 16);
    resultBuf.reserve(MAX_TRANSFER + 16);

    // Arrancar hilo receptor
    running = true;
    recvThread = std::thread([this]() { receiverLoop(); });
}

UnapiNet::~UnapiNet()
{
    // Parar hilo receptor
    running = false;
    if (recvThread.joinable()) {
        recvThread.join();
    }
    // Esperar hilo DNS si hay uno
    if (dnsThread.joinable()) {
        dnsThread.join();
    }
    closeAllConnections();
}

// ============================================================
//  Reset
// ============================================================

void UnapiNet::reset(EmuTime /*time*/)
{
    state     = State::IDLE;
    statusReg = STATUS_OK;
    paramBuf.clear();
    resultBuf.clear();
    resultPos = 0;

    closeAllConnections();

    dns.status = 0;
    dns.resolvedIP = 0;
    dns.errorCode = 0;
}

// ============================================================
//  Lectura de puertos
// ============================================================

byte UnapiNet::readIO(uint16_t port, EmuTime /*time*/)
{
    switch (port & 0xFF) {

    case 0x7E: // registro de status
        return statusReg;

    case 0x7F: // registro de datos
        if (state == State::RESULT_READY && resultPos < resultBuf.size()) {
            uint8_t b = resultBuf[resultPos++];
            if (resultPos >= resultBuf.size()) {
                state     = State::IDLE;
                statusReg = STATUS_OK;
            }
            return b;
        }
        return 0x00;

    default:
        return 0xFF;
    }
}

// ============================================================
//  Escritura de puertos
// ============================================================

void UnapiNet::writeIO(uint16_t port, byte value, EmuTime /*time*/)
{
    switch (port & 0xFF) {

    case 0x7E: // comando
        processCmd(value);
        break;

    case 0x7F: // parámetro (acumular)
        // Si hay resultado pendiente sin leer, descartarlo
        // para que los nuevos parámetros se acepten
        if (state == State::RESULT_READY) {
            state     = State::IDLE;
            statusReg = STATUS_OK;
            resultBuf.clear();
            resultPos = 0;
        }
        paramBuf.push_back(value);
        break;
    }
}

// ============================================================
//  Helpers de resultado
// ============================================================

void UnapiNet::setResult(const uint8_t* data, size_t len)
{
    resultBuf.assign(data, data + len);
    resultPos = 0;
    state     = State::RESULT_READY;
    statusReg = STATUS_DATA;
}

void UnapiNet::setResultVec(const std::vector<uint8_t>& v)
{
    resultBuf = v;
    resultPos = 0;
    state     = State::RESULT_READY;
    statusReg = STATUS_DATA;
}

void UnapiNet::setResultByte(uint8_t b)
{
    setResult(&b, 1);
}

void UnapiNet::setError()
{
    resultBuf.clear();
    resultPos = 0;
    state     = State::IDLE;
    statusReg = STATUS_ERROR;
}

// ============================================================
//  Gestión de handles TCP
// ============================================================

int UnapiNet::allocTcpHandle()
{
    for (int i = 0; i < MAX_TCP; i++) {
        if (tcp[i].sock == INVALID_SOCK &&
            tcp[i].tcpState == TCP_CLOSED) {
            return i + 1; // handles 1-based
        }
    }
    return 0; // no hay handles libres
}

void UnapiNet::closeTcpSocket(int h)
{
    if (h < 1 || h > MAX_TCP) return;
    auto& c = tcp[h - 1];
    if (c.sock != INVALID_SOCK) {
        sock_close(static_cast<SOCKET>(c.sock));
        c.sock = INVALID_SOCK;
    }
    c.tcpState   = TCP_CLOSED;
    c.connecting  = false;
    c.remoteIP    = 0;
    c.remotePort  = 0;
    c.localPort   = 0;
    c.resident    = false;
    {
        std::scoped_lock lock(c.mutex);
        c.recvBuf.clear();
    }
}

void UnapiNet::closeAllConnections()
{
    for (int i = 1; i <= MAX_TCP; i++) {
        closeTcpSocket(i);
        tcp[i - 1].closeReason = 1;
    }
    for (int i = 1; i <= MAX_UDP; i++) {
        closeUdpSocket(i);
    }
}

// ============================================================
//  Socket helpers
// ============================================================

void UnapiNet::setNonBlocking(intptr_t s)
{
    SOCKET sd = SOCK(s);
#ifdef _WIN32
    u_long mode = 1;
    ioctlsocket(sd, FIONBIO, &mode);
#else
    int flags = fcntl(sd, F_GETFL, 0);
    fcntl(sd, F_SETFL, flags | O_NONBLOCK);
#endif
}

uint32_t UnapiNet::getHostLocalIP()
{
    // Intenta obtener la IP local conectando un socket UDP a 8.8.8.8
    // sin enviar datos. getsockname() devuelve la IP de la interfaz usada.
    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == OPENMSX_INVALID_SOCKET) return 0;

    struct sockaddr_in remote;
    memset(&remote, 0, sizeof(remote));
    remote.sin_family = AF_INET;
    remote.sin_port = htons(53);
    inet_pton(AF_INET, "8.8.8.8", &remote.sin_addr);

    uint32_t ip = 0;
    if (connect(s, reinterpret_cast<struct sockaddr*>(&remote),
                sizeof(remote)) == 0) {
        struct sockaddr_in local;
        socklen_t len = sizeof(local);
        if (getsockname(s, reinterpret_cast<struct sockaddr*>(&local),
                        &len) == 0) {
            ip = ntohl(local.sin_addr.s_addr);
        }
    }
    sock_close(s);
    return ip;
}

// ============================================================
//  Hilo receptor de red (background)
//
//  Hace poll de todos los sockets TCP activos y mueve datos
//  entrantes al recvBuf de cada conexión.
//  También detecta finalización de connect() no-bloqueante y
//  transiciones de estado (cierre remoto, etc.).
// ============================================================

void UnapiNet::receiverLoop()
{
    while (running) {
        // Dormir un poco para no quemar CPU
        std::this_thread::sleep_for(std::chrono::milliseconds(10));

        for (int i = 0; i < MAX_TCP; i++) {
            auto& c = tcp[i];
            if (c.sock == INVALID_SOCK) continue;

            // --- Comprobar connect() pendiente ---
            SOCKET sd = SOCK(c.sock);
            if (c.connecting) {
                fd_set wfds, efds;
                FD_ZERO(&wfds);
                FD_ZERO(&efds);
                FD_SET(sd, &wfds);
                FD_SET(sd, &efds);
                struct timeval tv = {0, 0};

                int r = select(static_cast<int>(sd) + 1,
                               nullptr, &wfds, &efds, &tv);
                if (r > 0) {
                    if (FD_ISSET(sd, &efds)) {
                        c.tcpState    = TCP_CLOSED;
                        c.closeReason = 6;
                        c.connecting  = false;
                        sock_close(sd);
                        c.sock = INVALID_SOCK;
                    } else if (FD_ISSET(sd, &wfds)) {
                        int err = 0;
                        socklen_t elen = sizeof(err);
                        getsockopt(sd, SOL_SOCKET, SO_ERROR,
                                   reinterpret_cast<char*>(&err), &elen);
                        if (err == 0) {
                            c.tcpState   = TCP_ESTABLISHED;
                            c.connecting = false;
                        } else {
                            c.tcpState    = TCP_CLOSED;
                            c.closeReason = 6;
                            c.connecting  = false;
                            sock_close(sd);
                            c.sock = INVALID_SOCK;
                        }
                    }
                }
                continue;
            }

            // --- Leer datos entrantes si ESTABLISHED o CLOSE_WAIT ---
            if (c.tcpState != TCP_ESTABLISHED &&
                c.tcpState != TCP_CLOSE_WAIT) {
                continue;
            }

            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sd, &rfds);
            struct timeval tv = {0, 0};

            int r = select(static_cast<int>(sd) + 1,
                           &rfds, nullptr, nullptr, &tv);
            if (r <= 0) continue;

            char buf[512];
            auto n = sock_recv(sd, buf, sizeof(buf));
            if (n > 0) {
                std::scoped_lock lock(c.mutex);
                for (ptrdiff_t j = 0; j < n; j++) {
                    if (c.recvBuf.size() < MAX_RECV_BUF) {
                        c.recvBuf.push_back(static_cast<uint8_t>(buf[j]));
                    }
                }
            } else if (n == 0) {
                c.tcpState = TCP_CLOSE_WAIT;
            } else {
                c.tcpState    = TCP_CLOSED;
                c.closeReason = 4;
                sock_close(sd);
                c.sock = INVALID_SOCK;
            }
        }

        // --- Poll UDP sockets for incoming datagrams ---
        for (int i = 0; i < MAX_UDP; i++) {
            auto& u = udp[i];
            if (u.sock == INVALID_SOCK) continue;

            SOCKET sd = static_cast<SOCKET>(u.sock);
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sd, &rfds);
            struct timeval tv = {0, 0};

            if (select(static_cast<int>(sd) + 1,
                       &rfds, nullptr, nullptr, &tv) <= 0) continue;

            char buf[2048];
            struct sockaddr_in src;
            socklen_t slen = sizeof(src);
            int n = recvfrom(sd, buf, sizeof(buf), 0,
                             reinterpret_cast<struct sockaddr*>(&src), &slen);
            if (n <= 0) continue;

            UdpDatagram dg;
            dg.srcIP = ntohl(src.sin_addr.s_addr);
            dg.srcPort = ntohs(src.sin_port);
            dg.data.assign(buf, buf + n);

            std::scoped_lock lock(u.mutex);
            if (u.recvQueue.size() < 16) { // cap at 16 pending dgrams
                u.recvQueue.push_back(std::move(dg));
            }
        }
    }
}

// ============================================================
//  Procesado de comandos
// ============================================================

void UnapiNet::processCmd(uint8_t cmd)
{
    switch (cmd) {
    case CMD_PING:       cmdPing();      break;
    case CMD_QUERY_CAP:  cmdQueryCap();  break;
    case CMD_DNS_QUERY:  cmdDnsQuery();  break;
    case CMD_DNS_STATUS: cmdDnsStatus(); break;
    case CMD_TCP_OPEN:   cmdTcpOpen();   break;
    case CMD_TCP_SEND:   cmdTcpSend();   break;
    case CMD_TCP_RECV:   cmdTcpRecv();   break;
    case CMD_TCP_CLOSE:  cmdTcpClose();  break;
    case CMD_TCP_STATE:  cmdTcpState();  break;
    case CMD_TCP_ABORT:  cmdTcpAbort();  break;
    case CMD_GET_LOCALIP: cmdGetLocalIP(); break;
    case CMD_NET_STATE:  cmdNetState();  break;
    case CMD_UDP_OPEN:   cmdUdpOpen();   break;
    case CMD_UDP_CLOSE:  cmdUdpClose();  break;
    case CMD_UDP_STATE:  cmdUdpState();  break;
    case CMD_UDP_SEND:   cmdUdpSend();   break;
    case CMD_UDP_RECV:   cmdUdpRecv();   break;
    default:
        setError();
        break;
    }
    paramBuf.clear(); // siempre limpiar params tras comando
}

// ============================================================
//  PING (0x00) - Phase 1
// ============================================================

void UnapiNet::cmdPing()
{
    setResultByte(MAGIC);
}

// ============================================================
//  QUERY_CAP (0x10) - Phase 1+2
// ============================================================

void UnapiNet::cmdQueryCap()
{
    uint8_t buf[2] = {CAP_BYTE0, CAP_BYTE1};
    setResult(buf, 2);
}

// ============================================================
//  DNS_QUERY (0x01)
//  Params: hostname terminado en \0
//  Result: 1 byte status
//    0 = resolución en curso (async)
//    1 = resuelto inmediatamente (IP en bytes 1-4)
//    2 = resuelto localmente
//  Error si hostname vacío o ya hay query en curso
// ============================================================

void UnapiNet::cmdDnsQuery()
{
    if (paramBuf.empty()) {
        setError();
        return;
    }

    // Extraer hostname (null-terminated)
    std::string hostname(paramBuf.begin(), paramBuf.end());
    // Asegurar terminación
    auto pos = hostname.find('\0');
    if (pos != std::string::npos) {
        hostname.resize(pos);
    }

    if (hostname.empty()) {
        setError();
        return;
    }

    // ¿Es ya una dirección IP? Intentar parsear
    struct in_addr addr;
    if (inet_pton(AF_INET, hostname.c_str(), &addr) == 1) {
        // Es una IP directa
        uint32_t ip = ntohl(addr.s_addr);
        dns.resolvedIP = ip;
        dns.status = 2; // complete
        dns.errorCode = 0;

        uint8_t res[5];
        res[0] = 1; // resuelto inmediatamente
        res[1] = static_cast<uint8_t>((ip >> 24) & 0xFF);
        res[2] = static_cast<uint8_t>((ip >> 16) & 0xFF);
        res[3] = static_cast<uint8_t>((ip >>  8) & 0xFF);
        res[4] = static_cast<uint8_t>((ip >>  0) & 0xFF);
        setResult(res, 5);
        return;
    }

    // Resolución asíncrona
    if (dns.status == 1) {
        // Ya hay una query en curso
        setError();
        return;
    }

    dns.status = 1; // in_progress
    dns.resolvedIP = 0;
    dns.errorCode = 0;

    // Esperar hilo DNS anterior si quedó
    if (dnsThread.joinable()) {
        dnsThread.join();
    }

    dnsThread = std::thread([this, hostname]() {
        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;

        struct addrinfo* res = nullptr;
        int err = getaddrinfo(hostname.c_str(), nullptr, &hints, &res);
        if (err == 0 && res != nullptr) {
            auto* addr4 = reinterpret_cast<struct sockaddr_in*>(res->ai_addr);
            // Store IP in big-endian (network order) as-is
            // so bytes extract as octets: (ip>>24)=first, (ip>>0)=last
            dns.resolvedIP = ntohl(addr4->sin_addr.s_addr);
            dns.errorCode = 0;
            dns.status = 2; // complete
            freeaddrinfo(res);
        } else {
            if (res) freeaddrinfo(res);
            dns.errorCode = 3; // host name does not exist
            dns.status = 3; // error
        }
    });

    setResultByte(0); // query en curso
}

// ============================================================
//  DNS_STATUS (0x02)
//  Params: –
//  Result: 1 byte status + si complete: 4 bytes IP
//    0 = idle (no query)
//    1 = in_progress
//    2 = complete → +4 bytes IP
//    0xFF = error
// ============================================================

void UnapiNet::cmdDnsStatus()
{
    int s = dns.status.load();

    if (s == 2) {
        // Completo
        uint32_t ip = dns.resolvedIP;
        uint8_t res[5];
        res[0] = 2;
        res[1] = static_cast<uint8_t>((ip >> 24) & 0xFF);
        res[2] = static_cast<uint8_t>((ip >> 16) & 0xFF);
        res[3] = static_cast<uint8_t>((ip >>  8) & 0xFF);
        res[4] = static_cast<uint8_t>((ip >>  0) & 0xFF);
        setResult(res, 5);
    } else if (s == 3) {
        // Error
        uint8_t res[2];
        res[0] = 0xFF;
        res[1] = dns.errorCode;
        setResult(res, 2);
    } else {
        // idle (0) o in_progress (1)
        setResultByte(static_cast<uint8_t>(s));
    }
}

// ============================================================
//  TCP_OPEN (0x03)
//  Params: IP[4] + port[2] (little-endian)
//  Result: 1 byte handle (1-4, o 0 si error)
// ============================================================

void UnapiNet::cmdTcpOpen()
{
    if (paramBuf.size() < 6) {
        setResultByte(0); // error: params insuficientes
        return;
    }

    // Extraer IP (big-endian en params: a.b.c.d)
    uint32_t ip = (static_cast<uint32_t>(paramBuf[0]) << 24) |
                  (static_cast<uint32_t>(paramBuf[1]) << 16) |
                  (static_cast<uint32_t>(paramBuf[2]) <<  8) |
                  (static_cast<uint32_t>(paramBuf[3]) <<  0);

    // Extraer port (little-endian en params)
    uint16_t port = static_cast<uint16_t>(paramBuf[4]) |
                    (static_cast<uint16_t>(paramBuf[5]) << 8);

    int h = allocTcpHandle();
    if (h == 0) {
        setResultByte(0); // no hay handles libres
        return;
    }

    auto& c = tcp[h - 1];

    // Crear socket
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == OPENMSX_INVALID_SOCKET) {
        setResultByte(0);
        return;
    }

    // TCP_NODELAY
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY,
               reinterpret_cast<const char*>(&one), sizeof(one));

    // Non-blocking para connect asíncrono
    setNonBlocking(ISOCK(s));

    // Preparar dirección destino
    struct sockaddr_in dest;
    memset(&dest, 0, sizeof(dest));
    dest.sin_family = AF_INET;
    dest.sin_port = htons(port);
    dest.sin_addr.s_addr = htonl(ip);

    // Intentar connect
    int ret = connect(s, reinterpret_cast<struct sockaddr*>(&dest),
                      sizeof(dest));

    if (ret == 0) {
        // Conectado inmediatamente (raro con non-blocking, pero posible)
        c.sock       = ISOCK(s);
        c.tcpState   = TCP_ESTABLISHED;
        c.connecting = false;
    } else {
#ifdef _WIN32
        int err = WSAGetLastError();
        if (err == WSAEWOULDBLOCK) {
#else
        if (errno == EINPROGRESS) {
#endif
            // Connect en progreso
            c.sock       = ISOCK(s);
            c.tcpState   = TCP_SYN_SENT;
            c.connecting = true;
        } else {
            // Error real
            sock_close(s);
            setResultByte(0);
            return;
        }
    }

    c.closeReason = 0;
    c.remoteIP    = ip;
    c.remotePort  = port;
    c.resident    = false;
    {
        std::scoped_lock lock(c.mutex);
        c.recvBuf.clear();
    }

    // Obtener puerto local asignado
    struct sockaddr_in local;
    socklen_t len = sizeof(local);
    if (getsockname(SOCK(c.sock), reinterpret_cast<struct sockaddr*>(&local),
                    &len) == 0) {
        c.localPort = ntohs(local.sin_port);
    }

    setResultByte(static_cast<uint8_t>(h));
}

// ============================================================
//  TCP_SEND (0x04)
//  Params: handle[1] + len[2 LE] + data[len]
//  Result: 1 byte status (0=OK, 1=error)
// ============================================================

void UnapiNet::cmdTcpSend()
{
    if (paramBuf.size() < 3) {
        setResultByte(1);
        return;
    }

    int h = paramBuf[0];
    uint16_t len = static_cast<uint16_t>(paramBuf[1]) |
                   (static_cast<uint16_t>(paramBuf[2]) << 8);

    if (h < 1 || h > MAX_TCP) {
        setResultByte(1);
        return;
    }

    auto& c = tcp[h - 1];
    if (c.sock == INVALID_SOCK ||
        (c.tcpState != TCP_ESTABLISHED && c.tcpState != TCP_CLOSE_WAIT)) {
        setResultByte(1);
        return;
    }

    if (paramBuf.size() < static_cast<size_t>(3 + len)) {
        setResultByte(1);
        return;
    }

    // Enviar datos
    const char* data = reinterpret_cast<const char*>(paramBuf.data() + 3);
    size_t sent = 0;
    while (sent < len) {
        auto n = sock_send(SOCK(c.sock), data + sent, len - sent);
        if (n <= 0) {
            c.tcpState    = TCP_CLOSED;
            c.closeReason = 4;
            sock_close(SOCK(c.sock));
            c.sock = INVALID_SOCK;
            setResultByte(1);
            return;
        }
        sent += static_cast<size_t>(n);
    }

    setResultByte(0); // OK
}

// ============================================================
//  TCP_RECV (0x05)
//  Params: handle[1] + maxlen[2 LE]
//  Result: actual_len[2 LE] + data[actual_len]
// ============================================================

void UnapiNet::cmdTcpRecv()
{
    if (paramBuf.size() < 3) {
        // Devolver 0 bytes
        uint8_t res[2] = {0, 0};
        setResult(res, 2);
        return;
    }

    int h = paramBuf[0];
    uint16_t maxlen = static_cast<uint16_t>(paramBuf[1]) |
                      (static_cast<uint16_t>(paramBuf[2]) << 8);

    if (h < 1 || h > MAX_TCP) {
        uint8_t res[2] = {0, 0};
        setResult(res, 2);
        return;
    }

    auto& c = tcp[h - 1];

    // Limitar al máximo de transferencia
    if (maxlen > MAX_TRANSFER) maxlen = static_cast<uint16_t>(MAX_TRANSFER);

    std::vector<uint8_t> result;
    result.reserve(2 + maxlen);
    result.push_back(0); // placeholder len low
    result.push_back(0); // placeholder len high

    {
        std::scoped_lock lock(c.mutex);
        uint16_t avail = static_cast<uint16_t>(
            std::min(static_cast<size_t>(maxlen), c.recvBuf.size()));

        for (uint16_t i = 0; i < avail; i++) {
            result.push_back(c.recvBuf.front());
            c.recvBuf.pop_front();
        }

        result[0] = static_cast<uint8_t>(avail & 0xFF);
        result[1] = static_cast<uint8_t>((avail >> 8) & 0xFF);
    }

    setResultVec(result);
}

// ============================================================
//  TCP_CLOSE (0x06)
//  Params: handle[1]
//  Result: 1 byte status (0=OK)
// ============================================================

void UnapiNet::cmdTcpClose()
{
    if (paramBuf.empty()) {
        setResultByte(1);
        return;
    }

    int h = paramBuf[0];

    if (h == 0) {
        // Cerrar todas las conexiones transient
        for (int i = 0; i < MAX_TCP; i++) {
            if (!tcp[i].resident && tcp[i].sock != INVALID_SOCK) {
                tcp[i].closeReason = 2; // closed via TCPIP_TCP_CLOSE
                closeTcpSocket(i + 1);
            }
        }
        setResultByte(0);
        return;
    }

    if (h < 1 || h > MAX_TCP) {
        setResultByte(1);
        return;
    }

    auto& c = tcp[h - 1];
    if (c.sock == INVALID_SOCK) {
        setResultByte(1);
        return;
    }

    // Graceful shutdown: just FIN; let recvLoop detect remote close
    // and do the actual socket cleanup. Calling sock_close here can
    // deadlock with the recv thread on Windows.
#ifdef _WIN32
    shutdown(SOCK(c.sock), SD_SEND);
#else
    shutdown(SOCK(c.sock), SHUT_WR);
#endif
    c.closeReason = 2;
    c.tcpState = TCP_CLOSE_WAIT;

    setResultByte(0);
}

// ============================================================
//  TCP_STATE (0x07)
//  Params: handle[1]
//  Result: state[1] + avail_in[2 LE] + close_reason[1]
// ============================================================

void UnapiNet::cmdTcpState()
{
    if (paramBuf.empty()) {
        setError();
        return;
    }

    int h = paramBuf[0];
    if (h < 1 || h > MAX_TCP) {
        // Handle inválido → CLOSED con close_reason
        uint8_t res[4] = {TCP_CLOSED, 0, 0, 1}; // never used
        setResult(res, 4);
        return;
    }

    auto& c = tcp[h - 1];

    uint16_t avail;
    {
        std::scoped_lock lock(c.mutex);
        avail = static_cast<uint16_t>(
            std::min(c.recvBuf.size(), static_cast<size_t>(0xFFFF)));
    }

    uint8_t res[4];
    res[0] = static_cast<uint8_t>(c.tcpState);
    res[1] = static_cast<uint8_t>(avail & 0xFF);
    res[2] = static_cast<uint8_t>((avail >> 8) & 0xFF);
    res[3] = c.closeReason;
    setResult(res, 4);
}

// ============================================================
//  TCP_ABORT (0x08)
//  Params: handle[1]
//  Result: 1 byte status (0=OK)
// ============================================================

void UnapiNet::cmdTcpAbort()
{
    if (paramBuf.empty()) {
        setResultByte(1);
        return;
    }

    int h = paramBuf[0];
    if (h < 1 || h > MAX_TCP || tcp[h - 1].sock == INVALID_SOCK) {
        setResultByte(1);
        return;
    }

    tcp[h - 1].closeReason = 3; // aborted via TCPIP_TCP_ABORT
    closeTcpSocket(h);
    setResultByte(0);
}

// ============================================================
//  GET_LOCALIP (0x0D)
//  Params: –
//  Result: 4 bytes IP (big-endian: a.b.c.d)
// ============================================================

void UnapiNet::cmdGetLocalIP()
{
    uint32_t ip = getHostLocalIP();
    uint8_t res[4];
    res[0] = static_cast<uint8_t>((ip >> 24) & 0xFF);
    res[1] = static_cast<uint8_t>((ip >> 16) & 0xFF);
    res[2] = static_cast<uint8_t>((ip >>  8) & 0xFF);
    res[3] = static_cast<uint8_t>((ip >>  0) & 0xFF);
    setResult(res, 4);
}

// ============================================================
//  NET_STATE (0x0E)
//  Params: –
//  Result: 1 byte (0=closed, 1=opening, 2=open, 3=closing)
//  Siempre "open" porque usamos la red del host directamente.
// ============================================================

void UnapiNet::cmdNetState()
{
    setResultByte(2); // open
}

// ============================================================
//  UDP: handle management
// ============================================================

int UnapiNet::allocUdpHandle()
{
    for (int i = 0; i < MAX_UDP; i++) {
        if (udp[i].sock == INVALID_SOCK) {
            return i + 1;
        }
    }
    return 0;
}

void UnapiNet::closeUdpSocket(int h)
{
    if (h < 1 || h > MAX_UDP) return;
    auto& u = udp[h - 1];
    if (u.sock != INVALID_SOCK) {
        sock_close(static_cast<SOCKET>(u.sock));
        u.sock = INVALID_SOCK;
    }
    u.localPort = 0;
    u.resident = false;
    {
        std::scoped_lock lock(u.mutex);
        u.recvQueue.clear();
    }
}

// ============================================================
//  UDP_OPEN (0x09)
//  Params: local_port[2 LE] (0xFFFF = random)
//  Result: 1 byte handle (0 = error)
// ============================================================

void UnapiNet::cmdUdpOpen()
{
    if (paramBuf.size() < 2) {
        setResultByte(0);
        return;
    }
    uint16_t localPort = static_cast<uint16_t>(paramBuf[0]) |
                         (static_cast<uint16_t>(paramBuf[1]) << 8);

    int h = allocUdpHandle();
    if (h == 0) {
        setResultByte(0);
        return;
    }
    auto& u = udp[h - 1];

    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == OPENMSX_INVALID_SOCKET) {
        setResultByte(0);
        return;
    }

    setNonBlocking(ISOCK(s));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(localPort == 0xFFFF ? 0 : localPort);

    if (bind(s, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
        // Fallback: if bind to a privileged port (<1024) fails on Windows
        // without admin, fall back to a random port. MSX UDP clients
        // typically don't depend on a specific local port.
        addr.sin_port = 0;
        if (bind(s, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
            sock_close(s);
            setResultByte(0);
            return;
        }
    }

    // Read back actual local port
    socklen_t alen = sizeof(addr);
    if (getsockname(s, reinterpret_cast<struct sockaddr*>(&addr), &alen) == 0) {
        u.localPort = ntohs(addr.sin_port);
    } else {
        u.localPort = localPort;
    }

    u.sock = ISOCK(s);
    u.resident = false;
    {
        std::scoped_lock lock(u.mutex);
        u.recvQueue.clear();
    }

    setResultByte(static_cast<uint8_t>(h));
}

// ============================================================
//  UDP_CLOSE (0x0A)
//  Params: handle[1] (0 = close all transient)
//  Result: 1 byte status
// ============================================================

void UnapiNet::cmdUdpClose()
{
    if (paramBuf.empty()) {
        setResultByte(1);
        return;
    }
    int h = paramBuf[0];

    if (h == 0) {
        for (int i = 0; i < MAX_UDP; i++) {
            if (!udp[i].resident && udp[i].sock != INVALID_SOCK) {
                closeUdpSocket(i + 1);
            }
        }
        setResultByte(0);
        return;
    }

    if (h < 1 || h > MAX_UDP || udp[h - 1].sock == INVALID_SOCK) {
        setResultByte(1);
        return;
    }
    closeUdpSocket(h);
    setResultByte(0);
}

// ============================================================
//  UDP_STATE (0x0B)
//  Params: handle[1]
//  Result: 2 bytes: first datagram size (LE), 0 if none
// ============================================================

void UnapiNet::cmdUdpState()
{
    uint16_t size = 0;
    if (!paramBuf.empty()) {
        int h = paramBuf[0];
        if (h >= 1 && h <= MAX_UDP && udp[h - 1].sock != INVALID_SOCK) {
            auto& u = udp[h - 1];
            std::scoped_lock lock(u.mutex);
            if (!u.recvQueue.empty()) {
                size = static_cast<uint16_t>(
                    std::min(u.recvQueue.front().data.size(),
                             static_cast<size_t>(0xFFFF)));
            }
        }
    }
    uint8_t res[2] = {
        static_cast<uint8_t>(size & 0xFF),
        static_cast<uint8_t>((size >> 8) & 0xFF)
    };
    setResult(res, 2);
}

// ============================================================
//  UDP_SEND (0x0C)
//  Params: handle[1] + dest_IP[4] + dest_port[2 LE] + len[2 LE] + data
//  Result: 1 byte status
// ============================================================

void UnapiNet::cmdUdpSend()
{
    if (paramBuf.size() < 9) {
        setResultByte(1);
        return;
    }
    int h = paramBuf[0];
    if (h < 1 || h > MAX_UDP || udp[h - 1].sock == INVALID_SOCK) {
        setResultByte(1);
        return;
    }
    auto& u = udp[h - 1];

    uint32_t ip = (static_cast<uint32_t>(paramBuf[1]) << 24) |
                  (static_cast<uint32_t>(paramBuf[2]) << 16) |
                  (static_cast<uint32_t>(paramBuf[3]) <<  8) |
                  (static_cast<uint32_t>(paramBuf[4]) <<  0);
    uint16_t port = static_cast<uint16_t>(paramBuf[5]) |
                    (static_cast<uint16_t>(paramBuf[6]) << 8);
    uint16_t len = static_cast<uint16_t>(paramBuf[7]) |
                   (static_cast<uint16_t>(paramBuf[8]) << 8);

    if (paramBuf.size() < static_cast<size_t>(9 + len)) {
        setResultByte(1);
        return;
    }

    struct sockaddr_in dest;
    memset(&dest, 0, sizeof(dest));
    dest.sin_family = AF_INET;
    dest.sin_addr.s_addr = htonl(ip);
    dest.sin_port = htons(port);

    const char* data = reinterpret_cast<const char*>(paramBuf.data() + 9);
    int n = sendto(static_cast<SOCKET>(u.sock), data, len, 0,
                   reinterpret_cast<struct sockaddr*>(&dest), sizeof(dest));
    setResultByte(n == len ? 0 : 1);
}

// ============================================================
//  UDP_RECV (0x0F)
//  Params: handle[1] + maxlen[2 LE]
//  Result: src_IP[4] + src_port[2 LE] + actual_len[2 LE] + data
// ============================================================

void UnapiNet::cmdUdpRecv()
{
    if (paramBuf.size() < 3) {
        uint8_t res[8] = {0};
        setResult(res, 8);
        return;
    }
    int h = paramBuf[0];
    uint16_t maxlen = static_cast<uint16_t>(paramBuf[1]) |
                      (static_cast<uint16_t>(paramBuf[2]) << 8);

    if (h < 1 || h > MAX_UDP || udp[h - 1].sock == INVALID_SOCK) {
        uint8_t res[8] = {0};
        setResult(res, 8);
        return;
    }
    auto& u = udp[h - 1];

    UdpDatagram dg;
    bool haveDg = false;
    {
        std::scoped_lock lock(u.mutex);
        if (!u.recvQueue.empty()) {
            dg = std::move(u.recvQueue.front());
            u.recvQueue.pop_front();
            haveDg = true;
        }
    }

    if (!haveDg) {
        uint8_t res[8] = {0};
        setResult(res, 8);
        return;
    }

    uint16_t actual = static_cast<uint16_t>(
        std::min(static_cast<size_t>(maxlen), dg.data.size()));

    std::vector<uint8_t> result;
    result.reserve(8 + actual);
    result.push_back(static_cast<uint8_t>((dg.srcIP >> 24) & 0xFF));
    result.push_back(static_cast<uint8_t>((dg.srcIP >> 16) & 0xFF));
    result.push_back(static_cast<uint8_t>((dg.srcIP >>  8) & 0xFF));
    result.push_back(static_cast<uint8_t>((dg.srcIP >>  0) & 0xFF));
    result.push_back(static_cast<uint8_t>(dg.srcPort & 0xFF));
    result.push_back(static_cast<uint8_t>((dg.srcPort >> 8) & 0xFF));
    result.push_back(static_cast<uint8_t>(actual & 0xFF));
    result.push_back(static_cast<uint8_t>((actual >> 8) & 0xFF));
    for (uint16_t i = 0; i < actual; i++) {
        result.push_back(dg.data[i]);
    }
    setResultVec(result);
}

// ============================================================
//  Serialización (save state)
//  No serializamos sockets ni estado de red.
//  En restore, las conexiones se pierden.
// ============================================================

template<typename Archive>
void UnapiNet::serialize(Archive& ar, unsigned /*version*/)
{
    ar.template serializeBase<MSXDevice>(*this);
    // No serializar estado de red - las conexiones se pierden en save/load
}

INSTANTIATE_SERIALIZE_METHODS(UnapiNet);
REGISTER_MSXDEVICE(UnapiNet, "UnapiNet");

} // namespace openmsx
