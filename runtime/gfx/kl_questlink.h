// The QuestLinkMac frontend: a Quest headset, reached over Steam Link/Air Link
// through QuestLinkMac's tracked backend and HEVC encoder, standing in for the
// viewer's WASD head and emulated hands. Poses come in from the headset; the
// guest's finished eye textures go out, GPU to GPU, with the pose they were
// rendered from so the headset can reproject.
//
// Only built when the Makefile is given QLM_BUILD (see BUILDING.md), and only
// started under KL_QUESTLINK=1. The viewer window keeps running beside it as a
// monitor; its own head and controller emulation stand down.
#ifndef KL_QUESTLINK_H
#define KL_QUESTLINK_H

// Before the guest thread exists: connects to the service, waits for a headset
// (KL_QUESTLINK_WAIT_MS, default 30000), and pushes the display's real rate,
// eye size, frustum and IPD into kl_ovrp. Returns 0 if there is no headset,
// in which case nothing was changed.
int  kl_questlink_start(void);
void kl_questlink_stop(void);

#endif
