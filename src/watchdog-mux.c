#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/epoll.h>

#include <linux/types.h>
#include <linux/watchdog.h>

#include <systemd/sd-daemon.h>

#define MY_SOCK_PATH "/run/watchdog-mux.sock"
#define LISTEN_BACKLOG 50
#define MAX_EVENTS 10

#define WATCHDOG_DEV "/dev/watchdog"

int watchdog_fd = -1;
int watchdog_timeout = 20;


typedef struct {
    int fd;
    int time;
} wd_client_t;

#define MAX_CLIENTS 100

static wd_client_t client_list[MAX_CLIENTS];

static wd_client_t *
alloc_client(int fd)
{
    int i;

    for (i = 0; i < MAX_CLIENTS; i++) {
        if (client_list[i].fd == 0) {
            memset(&client_list[i], 1, sizeof(wd_client_t));
            client_list[i].fd = fd;
            return &client_list[i];
        }
    }

    return NULL;
}

static void
free_client(wd_client_t *wd_client)
{
    if (!wd_client)
        return;

    wd_client->fd = 0;
}

static void 
watchdog_close(void)
{
    if (watchdog_fd != -1) {
        if (write(watchdog_fd, "V", 1) == -1) {
            perror("write magic watchdog close");
        }
        if (close(watchdog_fd) == -1) {
            perror("write magic watchdog close");
        }
    }

    watchdog_fd = -1;
}
 
int 
main(void)
{
    struct sockaddr_un my_addr, peer_addr;
    socklen_t peer_addr_size;
    struct epoll_event ev, events[MAX_EVENTS];
    int socket_count, listen_sock, nfds, epollfd;

    struct stat fs;
    if (stat(WATCHDOG_DEV, &fs) == -1) {
        system("modprobe -q softdog soft_noboot=1"); // fixme
    }

    if ((watchdog_fd = open(WATCHDOG_DEV, O_WRONLY)) == -1) {
         perror("watchdog open");
         exit(EXIT_FAILURE);
    }
       
    if (ioctl(watchdog_fd, WDIOC_SETTIMEOUT, &watchdog_timeout) == -1) {
        perror("watchdog set timeout");
        watchdog_close();
        exit(EXIT_FAILURE);
    }

    /* read and log watchdog identity */
    struct watchdog_info wdinfo;
    if (ioctl(watchdog_fd, WDIOC_GETSUPPORT, &wdinfo) == -1) {
        perror("read watchdog info");
        watchdog_close();
        exit(EXIT_FAILURE);
    }

    wdinfo.identity[sizeof(wdinfo.identity) - 1] = 0; // just to be sure
    fprintf(stderr, "Watchdog driver '%s', version %x\n",
            wdinfo.identity, wdinfo.firmware_version);

    socket_count = sd_listen_fds(0);

    if (socket_count > 1) {

        perror("too many file descriptors received.\n");
        goto err;
	    
    } else if (socket_count == 1) {

        listen_sock = SD_LISTEN_FDS_START + 0;
	    
    } else {

        unlink(MY_SOCK_PATH);

        listen_sock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (listen_sock == -1) {
            perror("socket create");
            exit(EXIT_FAILURE);
        }

        memset(&my_addr, 0, sizeof(struct sockaddr_un));
        my_addr.sun_family = AF_UNIX;
        strncpy(my_addr.sun_path, MY_SOCK_PATH, sizeof(my_addr.sun_path) - 1);
	    
        if (bind(listen_sock, (struct sockaddr *) &my_addr,
                 sizeof(struct sockaddr_un)) == -1) {
	    perror("socket bind");
	    exit(EXIT_FAILURE);
        }
   
        if (listen(listen_sock, LISTEN_BACKLOG) == -1) {
	    perror("socket listen");
	    goto err;
        }
    }
    
    epollfd = epoll_create(10);
    if (epollfd == -1) {
        perror("epoll_create");
        goto err;
    }

    ev.events = EPOLLIN;
    ev.data.ptr = alloc_client(listen_sock);
    if (epoll_ctl(epollfd, EPOLL_CTL_ADD, listen_sock, &ev) == -1) {
        perror("epoll_ctl: listen_sock");
        goto err;
    }

    for (;;) {
        nfds = epoll_wait(epollfd, events, MAX_EVENTS, 1000);
        if (nfds == -1) {
            if (errno == EINTR)
                continue;
            
            perror("epoll_pwait");
            goto err;
        }

        if (nfds == 0) { // timeout

            if (ioctl(watchdog_fd, WDIOC_KEEPALIVE, 0) == -1) {
                perror("watchdog update failed");
            }
            
            continue;
        }

        int n;
        for (n = 0; n < nfds; ++n) {
            wd_client_t *wd_client = events[n].data.ptr;
            if (wd_client->fd == listen_sock) {
                int conn_sock = accept(listen_sock, (struct sockaddr *) &peer_addr, &peer_addr_size);
                if (conn_sock == -1) {
                    perror("accept");
                    goto err; // fixme
                }
                if (fcntl(conn_sock, F_SETFL, O_NONBLOCK) == -1) {
                    perror("setnonblocking");
                    goto err; // fixme
                }

                wd_client_t *new_client = alloc_client(conn_sock);
                if (new_client == NULL) {
                    fprintf(stderr, "unable to alloc wd_client structure\n");
                    goto err; // fixme;
                }
                ev.events = EPOLLIN;
                ev.data.ptr = new_client;
                if (epoll_ctl(epollfd, EPOLL_CTL_ADD, conn_sock, &ev) == -1) {
                    perror("epoll_ctl: add conn_sock");
                    goto err; // fixme                   
                }
            } else {
                char buf[4096];
                int cfd = wd_client->fd;

                ssize_t bytes = read(cfd, buf, sizeof(buf));
                if (bytes == -1) {
                    perror("read");
                    goto err; // fixme                   
                } else if (bytes > 0) {
                    fprintf(stderr, "GOT %zd bytes\n", bytes);
                } else {
                    if (events[n].events & EPOLLHUP || events[n].events & EPOLLERR) {
                        printf("GOT %016x event\n", events[n].events);
                        if (epoll_ctl(epollfd, EPOLL_CTL_DEL, cfd, NULL) == -1) {
                            perror("epoll_ctl: del conn_sock");
                            goto err; // fixme                   
                        }
                        if (close(cfd) == -1) {
                            perror("close conn_sock");
                            goto err; // fixme                   
                        }
                        fprintf(stderr, "close client connection\n");
                        free_client(wd_client);
                    }
                }
            }
        }
    }

    printf("DONE\n");

// out:

    watchdog_close();
    unlink(MY_SOCK_PATH);
    exit(EXIT_SUCCESS);

err:
    unlink(MY_SOCK_PATH);
    exit(EXIT_FAILURE);
}
