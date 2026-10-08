// C APIs Swift cannot reach on its own: zlib (VNC ZRLE/Tight streams),
// pty helpers, termios and ioctl for serial consoles.
#include <zlib.h>
#include <util.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <fcntl.h>
#include <unistd.h>
#include <libproc.h>
