#ifndef UNAPINET_HH
#define UNAPINET_HH

#include "MSXDevice.hh"

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// ============================================================
//  UnapiNet  –  openMSX Extension  (Phase 2)
//
//  Puertos I/O 0x0B (cmd/status) y 0x0C (data). Rango libre según el
//  mapa de I/O ports de Grauw (map.grauw.nl/resources/msx_io_ports.php).
//  Bridge entre MSX y sockets BSD del host.
//  No incluimos Socket.hh aquí para evitar conflicto con
//  la macro "interface" de windows.h.
// ============================================================

namespace openmsx {

class UnapiNet final : public MSXDevice
{
public:
    explicit UnapiNet(const DeviceConfig& config);
    ~UnapiNet() override;

    void reset(EmuTime time) override;
    [[nodiscard]] byte readIO(uint16_t port, EmuTime time) override;
    void writeIO(uint16_t port, byte value, EmuTime time) override;

    template<typename Archive>
    void serialize(Archive& ar, unsigned version);

private:
    // --- Estado del protocolo I/O ---
    enum class State { IDLE, RESULT_READY };
    State    state;
    uint8_t  statusReg;

    // Buffer de parámetros (escritos a 0x0C antes del comando)
    std::vector<uint8_t> paramBuf;

    // Buffer de resultado (leído desde 0x0C tras comando)
    std::vector<uint8_t> resultBuf;
    size_t resultPos;

    // --- Comandos bridge ---
    static constexpr uint8_t CMD_PING       = 0x00;
    static constexpr uint8_t CMD_DNS_QUERY  = 0x01;
    static constexpr uint8_t CMD_DNS_STATUS = 0x02;
    static constexpr uint8_t CMD_TCP_OPEN   = 0x03;
    static constexpr uint8_t CMD_TCP_SEND   = 0x04;
    static constexpr uint8_t CMD_TCP_RECV   = 0x05;
    static constexpr uint8_t CMD_TCP_CLOSE  = 0x06;
    static constexpr uint8_t CMD_TCP_STATE  = 0x07;
    static constexpr uint8_t CMD_TCP_ABORT  = 0x08;
    static constexpr uint8_t CMD_UDP_OPEN   = 0x09;
    static constexpr uint8_t CMD_UDP_CLOSE  = 0x0A;
    static constexpr uint8_t CMD_UDP_STATE  = 0x0B;
    static constexpr uint8_t CMD_UDP_SEND   = 0x0C;
    static constexpr uint8_t CMD_GET_LOCALIP = 0x0D;
    static constexpr uint8_t CMD_NET_STATE  = 0x0E;
    static constexpr uint8_t CMD_UDP_RECV   = 0x0F;
    static constexpr uint8_t CMD_QUERY_CAP  = 0x10;
    static constexpr uint8_t CMD_ICMP_SEND  = 0x11;
    static constexpr uint8_t CMD_ICMP_RECV  = 0x12;

    // --- Status register values ---
    static constexpr uint8_t STATUS_OK    = 0x00;
    static constexpr uint8_t STATUS_ERROR = 0x01;
    static constexpr uint8_t STATUS_DATA  = 0x02;

    static constexpr uint8_t MAGIC = 0xAB;

    // --- Conexiones TCP ---
    static constexpr int MAX_TCP = 4;

    // Estados TCP (UNAPI spec)
    enum TcpState : uint8_t {
        TCP_CLOSED      = 0,
        TCP_LISTEN      = 1,
        TCP_SYN_SENT    = 2,
        TCP_SYN_RECV    = 3,
        TCP_ESTABLISHED = 4,
        TCP_FIN_WAIT1   = 5,
        TCP_FIN_WAIT2   = 6,
        TCP_CLOSE_WAIT  = 7,
        TCP_CLOSING     = 8,
        TCP_LAST_ACK    = 9,
        TCP_TIME_WAIT   = 10,
    };

    // Usamos intptr_t en vez de SOCKET para evitar incluir
    // winsock2.h en el header (conflicto con macro "interface").
    // El cast real se hace en el .cc.
    static constexpr intptr_t INVALID_SOCK = -1;

    struct TcpConnection {
        intptr_t sock = INVALID_SOCK;
        std::atomic<uint8_t> tcpState{TCP_CLOSED};
        uint8_t  closeReason = 1;   // 1 = never used
        bool     resident = false;
        uint32_t remoteIP = 0;
        uint16_t remotePort = 0;
        uint16_t localPort = 0;
        bool     connecting = false;
        std::deque<uint8_t> recvBuf;
        std::mutex mutex;
    };
    TcpConnection tcp[MAX_TCP]; // handles 1..MAX_TCP

    // --- Conexiones UDP ---
    static constexpr int MAX_UDP = 4;

    struct UdpDatagram {
        uint32_t srcIP = 0;
        uint16_t srcPort = 0;
        std::vector<uint8_t> data;
    };

    struct UdpConnection {
        intptr_t sock = INVALID_SOCK;
        uint16_t localPort = 0;
        bool     resident = false;
        std::deque<UdpDatagram> recvQueue;
        std::mutex mutex;
    };
    UdpConnection udp[MAX_UDP];

    // --- ICMP echo reply queue ---
    struct IcmpReply {
        uint32_t srcIP = 0;
        uint8_t  ttl = 0;
        uint16_t identifier = 0;
        uint16_t sequence = 0;
        uint16_t dataLen = 0;
    };
    std::deque<IcmpReply> icmpReplies;
    std::mutex icmpMutex;
    std::thread icmpWorker;
    std::atomic<bool> icmpPending{false};
    // ICMP request for worker to handle
    struct IcmpRequest {
        uint32_t dstIP;
        uint8_t  ttl;
        uint16_t identifier;
        uint16_t sequence;
        uint16_t dataLen;
    } icmpRequest;

    // --- DNS asíncrono ---
    struct {
        std::atomic<int> status{0}; // 0=idle 1=in_progress 2=complete 3=error
        uint32_t resolvedIP = 0;
        uint8_t  errorCode = 0;
    } dns;
    std::thread dnsThread;

    // --- Hilo receptor de red ---
    std::thread recvThread;
    std::atomic<bool> running{false};
    void receiverLoop();

    // --- Procesado de comandos ---
    void processCmd(uint8_t cmd);
    void cmdPing();
    void cmdQueryCap();
    void cmdDnsQuery();
    void cmdDnsStatus();
    void cmdTcpOpen();
    void cmdTcpSend();
    void cmdTcpRecv();
    void cmdTcpClose();
    void cmdTcpState();
    void cmdTcpAbort();
    void cmdGetLocalIP();
    void cmdNetState();
    void cmdUdpOpen();
    void cmdUdpClose();
    void cmdUdpState();
    void cmdUdpSend();
    void cmdUdpRecv();
    void cmdIcmpSend();
    void cmdIcmpRecv();
    void icmpWorkerLoop();

    // --- Helpers ---
    void setResult(const uint8_t* data, size_t len);
    void setResultVec(const std::vector<uint8_t>& v);
    void setResultByte(uint8_t b);
    void setError();

    int  allocTcpHandle();
    void closeTcpSocket(int h);
    int  allocUdpHandle();
    void closeUdpSocket(int h);
    void closeAllConnections();

    static void setNonBlocking(intptr_t s);
    static uint32_t getHostLocalIP();
};

} // namespace openmsx

#endif // UNAPINET_HH
