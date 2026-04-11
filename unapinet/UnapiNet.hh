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
//  Puertos I/O 0x7E (cmd/status) y 0x7F (data).
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

    // Buffer de parámetros (escritos a 0x7F antes del comando)
    std::vector<uint8_t> paramBuf;

    // Buffer de resultado (leído desde 0x7F tras comando)
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
    static constexpr uint8_t CMD_GET_LOCALIP = 0x0D;
    static constexpr uint8_t CMD_NET_STATE  = 0x0E;
    static constexpr uint8_t CMD_QUERY_CAP  = 0x10;

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

    // --- Helpers ---
    void setResult(const uint8_t* data, size_t len);
    void setResultVec(const std::vector<uint8_t>& v);
    void setResultByte(uint8_t b);
    void setError();

    int  allocTcpHandle();
    void closeTcpSocket(int h);
    void closeAllConnections();

    static void setNonBlocking(intptr_t s);
    static uint32_t getHostLocalIP();
};

} // namespace openmsx

#endif // UNAPINET_HH
