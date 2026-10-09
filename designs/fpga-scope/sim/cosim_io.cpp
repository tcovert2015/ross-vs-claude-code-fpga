// cosim_io.cpp — DPI-C byte bridge for the tb_cosim Verilator co-simulation (issue #10).
//
// The Python host (host/fpgapa_scope + pytest) drives the *real* scope_top RTL over a byte
// stream. To keep that stream isolated from Verilator's / the TB's own stdout+stderr chatter,
// the two directions ride DEDICATED pipe fds the parent passes in via environment variables:
//
//   COSIM_RX_FD  — host -> DUT   (this process reads;  set non-blocking so the free-running
//                                 clock never stalls waiting for a byte)
//   COSIM_TX_FD  — DUT  -> host  (this process writes)
//
// cosim_rx_byte() returns 0..255 for a byte, -1 when none is available right now, and -2 on
// EOF (the parent closed its write end -> the TB should $finish). Falls back to stdin/stdout
// (fd 0/1) if the env vars are unset, which is handy for manual poking.
#include <cstdlib>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

extern "C" {

static int  rx_fd = -1;
static int  tx_fd = -1;
static bool inited = false;

static void cosim_init() {
  const char *r = getenv("COSIM_RX_FD");
  const char *t = getenv("COSIM_TX_FD");
  rx_fd = r ? atoi(r) : 0;   // default stdin
  tx_fd = t ? atoi(t) : 1;   // default stdout
  int fl = fcntl(rx_fd, F_GETFL, 0);
  if (fl != -1) fcntl(rx_fd, F_SETFL, fl | O_NONBLOCK);
  inited = true;
}

// -2 = EOF, -1 = no byte available now, 0..255 = a received byte
int cosim_rx_byte() {
  if (!inited) cosim_init();
  unsigned char c;
  ssize_t n = read(rx_fd, &c, 1);
  if (n == 1) return (int)c;
  if (n == 0) return -2;                                   // writer closed -> EOF
  if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;  // nothing ready yet
  return -1;                                               // treat other errors as "no byte"
}

void cosim_tx_byte(int b) {
  if (!inited) cosim_init();
  unsigned char c = (unsigned char)(b & 0xFF);
  ssize_t n = write(tx_fd, &c, 1);
  (void)n;  // a pipe write of 1 byte either succeeds or the reader is gone; TB will EOF-exit
}

}  // extern "C"
