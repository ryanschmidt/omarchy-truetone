// truetone-gamma: holds a wlr-gamma-control ramp open for every output.
//
// Why this exists at all: a gamma ramp is released the moment its client
// disconnects, so applying one needs a resident process. It also keeps True
// Tone off hyprsunset's colour transform matrix, which Omarchy's Night Light
// owns exclusively. Two channels, composed by the compositor, so the two
// features stack instead of fighting over one number.
//
// This program is deliberately stupid. It does no colour science. It watches
// one small file and writes whatever gains it finds there to every output:
//
//     <r> <g> <b>         gains in 0..1, e.g. 1.000 0.871 0.752
//
// All the science lives in TrueToneModel.js, where it is testable.
//
// The file is watched with inotify rather than polled, so an idle session
// costs nothing. A command channel on stdin was tried first; Quickshell
// closes the child's stdin, which the helper correctly read as "my parent is
// gone" and exited. Lifetime is instead tied to the parent with
// PR_SET_PDEATHSIG, so the helper cannot outlive the shell and strand a
// tinted screen. On exit the compositor restores the original ramps.

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/inotify.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <signal.h>
#include <poll.h>
#include <libgen.h>
#include <wayland-client.h>
#include "wlr-gamma-control-unstable-v1-client-protocol.h"

#define MAX_OUTPUTS 16

struct output_state {
  struct wl_output *output;
  uint32_t name;                          // registry name, for hotplug removal
  struct zwlr_gamma_control_v1 *gamma;
  uint32_t ramp_size;
  int fd;
  uint16_t *table;
  int ready;
  int failed;
};

static struct wl_display *display;
static struct wl_registry *registry;
static struct zwlr_gamma_control_manager_v1 *manager;
static struct output_state outputs[MAX_OUTPUTS];
static int output_count;
static double cur_r = 1.0, cur_g = 1.0, cur_b = 1.0;

static void apply_one(struct output_state *o, double r, double g, double b);

// ---- gamma control listener ------------------------------------------------

static void gamma_size(void *data, struct zwlr_gamma_control_v1 *gc, uint32_t size) {
  struct output_state *o = data;
  // The compositor can re-announce a size. Re-allocating underneath a live
  // mapping produced "Gamma ramps size mismatch"; keep the first allocation
  // unless the size genuinely changed.
  if (o->ready && o->ramp_size == size) { apply_one(o, cur_r, cur_g, cur_b); return; }
  if (o->table) { munmap(o->table, (size_t)o->ramp_size * 3 * sizeof(uint16_t)); o->table = NULL; }
  if (o->fd >= 0) { close(o->fd); o->fd = -1; }
  o->ready = 0;
  o->ramp_size = size;

  size_t bytes = (size_t)size * 3 * sizeof(uint16_t);
  char tmpl[] = "/tmp/truetone-gamma-XXXXXX";
  o->fd = mkstemp(tmpl);
  if (o->fd < 0) { o->failed = 1; return; }
  unlink(tmpl);
  if (ftruncate(o->fd, bytes) < 0) { o->failed = 1; return; }
  o->table = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, o->fd, 0);
  if (o->table == MAP_FAILED) { o->table = NULL; o->failed = 1; return; }

  o->ready = 1;
  // A newly attached output should match whatever is currently set, so a
  // monitor plugged in mid-session does not sit at identity.
  apply_one(o, cur_r, cur_g, cur_b);
}

// Sent when another client takes the gamma control for this output. Not fatal:
// the rest of the outputs keep working.
static void gamma_failed(void *data, struct zwlr_gamma_control_v1 *gc) {
  struct output_state *o = data;
  o->failed = 1;
  o->ready = 0;
  fprintf(stderr, "truetone-gamma: gamma control refused for one output "
                  "(another client holds it)\n");
  fflush(stderr);
}

static const struct zwlr_gamma_control_v1_listener gamma_listener = {
  .gamma_size = gamma_size,
  .failed = gamma_failed,
};

// ---- ramp writing ----------------------------------------------------------

static void apply_one(struct output_state *o, double r, double g, double b) {
  if (!o->ready || !o->table || o->failed) return;

  uint32_t n = o->ramp_size;
  uint16_t *R = o->table;
  uint16_t *G = o->table + n;
  uint16_t *B = o->table + 2 * n;

  for (uint32_t i = 0; i < n; i++) {
    double v = (n > 1) ? ((double)i / (double)(n - 1)) * 65535.0 : 0.0;
    double vr = v * r, vg = v * g, vb = v * b;
    R[i] = (uint16_t)(vr < 0 ? 0 : (vr > 65535 ? 65535 : vr));
    G[i] = (uint16_t)(vg < 0 ? 0 : (vg > 65535 ? 65535 : vg));
    B[i] = (uint16_t)(vb < 0 ? 0 : (vb > 65535 ? 65535 : vb));
  }

  // set_gamma consumes the fd, so hand over a duplicate and keep ours.
  //
  // dup() shares the file offset with the original. The compositor reads the
  // ramp through its copy, which advances that shared offset, so the next
  // hand-off started past the beginning and the compositor rejected it with
  // "Gamma ramps size mismatch". Rewind before every duplicate.
  if (lseek(o->fd, 0, SEEK_SET) < 0) return;
  int dup_fd = dup(o->fd);
  if (dup_fd < 0) return;
  zwlr_gamma_control_v1_set_gamma(o->gamma, dup_fd);
}

static void apply_all(double r, double g, double b) {
  cur_r = r; cur_g = g; cur_b = b;
  for (int i = 0; i < output_count; i++) apply_one(&outputs[i], r, g, b);
  wl_display_flush(display);
}

// ---- registry --------------------------------------------------------------

static void add_output(uint32_t name, uint32_t version) {
  if (output_count >= MAX_OUTPUTS) return;
  struct output_state *o = &outputs[output_count];
  memset(o, 0, sizeof(*o));
  o->fd = -1;
  o->name = name;
  o->output = wl_registry_bind(registry, name, &wl_output_interface,
                               version < 4 ? version : 4);
  if (!manager) return;
  o->gamma = zwlr_gamma_control_manager_v1_get_gamma_control(manager, o->output);
  zwlr_gamma_control_v1_add_listener(o->gamma, &gamma_listener, o);
  output_count++;
}

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
                            const char *iface, uint32_t version) {
  if (!strcmp(iface, zwlr_gamma_control_manager_v1_interface.name)) {
    manager = wl_registry_bind(reg, name,
                               &zwlr_gamma_control_manager_v1_interface, 1);
  } else if (!strcmp(iface, wl_output_interface.name)) {
    add_output(name, version);
  }
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
  for (int i = 0; i < output_count; i++) {
    if (outputs[i].name != name) continue;
    if (outputs[i].gamma) zwlr_gamma_control_v1_destroy(outputs[i].gamma);
    if (outputs[i].table) munmap(outputs[i].table,
                                 (size_t)outputs[i].ramp_size * 3 * sizeof(uint16_t));
    if (outputs[i].fd >= 0) close(outputs[i].fd);
    if (outputs[i].output) wl_output_destroy(outputs[i].output);
    outputs[i] = outputs[output_count - 1];
    output_count--;
    return;
  }
}

static const struct wl_registry_listener registry_listener = {
  .global = registry_global,
  .global_remove = registry_global_remove,
};

// ---- main ------------------------------------------------------------------

static int read_gains_file(const char *path, double *r, double *g, double *b) {
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  double rr, gg, bb;
  int n = fscanf(f, "%lf %lf %lf", &rr, &gg, &bb);
  fclose(f);
  if (n != 3) return 0;
  if (rr < 0 || gg < 0 || bb < 0 || rr > 1.5 || gg > 1.5 || bb > 1.5) return 0;
  *r = rr; *g = gg; *b = bb;
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: truetone-gamma <gains-file>\n");
    return 1;
  }
  const char *gains_path = argv[1];

  // Die with the shell rather than stranding a tinted screen.
  prctl(PR_SET_PDEATHSIG, SIGTERM);

  // Load before connecting: gamma_size applies cur_* as each output appears,
  // so there is exactly one write per output rather than two.
  read_gains_file(gains_path, &cur_r, &cur_g, &cur_b);

  display = wl_display_connect(NULL);
  if (!display) {
    fprintf(stderr, "truetone-gamma: no wayland display\n");
    return 1;
  }

  registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);

  // First trip binds the manager, the rest bind outputs against it.
  wl_display_roundtrip(display);
  if (!manager) {
    fprintf(stderr, "truetone-gamma: compositor does not support "
                    "zwlr_gamma_control_manager_v1\n");
    return 1;
  }
  wl_display_roundtrip(display);
  wl_display_roundtrip(display);

  if (output_count == 0) {
    fprintf(stderr, "truetone-gamma: no outputs\n");
    return 1;
  }

  // Watch the directory, not the file: an atomic rename replaces the inode
  // and a watch on the old one would go deaf.
  char dirbuf[512];
  snprintf(dirbuf, sizeof(dirbuf), "%s", gains_path);
  char *dir = dirname(dirbuf);
  char namebuf[512];
  snprintf(namebuf, sizeof(namebuf), "%s", gains_path);
  char *base = basename(namebuf);

  int ino = inotify_init1(IN_CLOEXEC);
  if (ino < 0) { perror("inotify_init1"); return 1; }
  if (inotify_add_watch(ino, dir, IN_CLOSE_WRITE | IN_MOVED_TO) < 0) {
    perror("inotify_add_watch");
    return 1;
  }

  double r = cur_r, g = cur_g, b = cur_b;

  printf("READY %d\n", output_count);
  fflush(stdout);

  struct pollfd fds[2];
  fds[0].fd = wl_display_get_fd(display); fds[0].events = POLLIN;
  fds[1].fd = ino;                        fds[1].events = POLLIN;

  char evbuf[4096];
  for (;;) {
    while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
    wl_display_flush(display);

    if (poll(fds, 2, -1) < 0) {
      wl_display_cancel_read(display);
      if (errno == EINTR) continue;
      break;
    }

    if (fds[0].revents & POLLIN) {
      wl_display_read_events(display);
      wl_display_dispatch_pending(display);
    } else {
      wl_display_cancel_read(display);
    }

    if (fds[1].revents & POLLIN) {
      ssize_t len = read(ino, evbuf, sizeof(evbuf));
      int touched = 0;
      for (char *p = evbuf; len > 0 && p < evbuf + len; ) {
        struct inotify_event *e = (struct inotify_event *)p;
        if (e->len && !strcmp(e->name, base)) touched = 1;
        p += sizeof(struct inotify_event) + e->len;
      }
      if (touched && read_gains_file(gains_path, &r, &g, &b)) {
        apply_all(r, g, b);
        printf("SET %.3f %.3f %.3f\n", r, g, b);
        fflush(stdout);
      }
    }
  }

  wl_display_disconnect(display);
  return 0;
}
