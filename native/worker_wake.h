/* A full notification pipe already contains a wakeup. Never block the game
 * thread waiting for a worker that might be busy in Xlib or have exited. */
#ifndef QUINTA_WORKER_WAKE_H
#define QUINTA_WORKER_WAKE_H
int quinta_wake_pipe(int descriptors[2]);
void quinta_wake_worker(int descriptor);
#endif
