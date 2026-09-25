// The handful of libVLC C functions the app's own frame grabber (VLCSnapshotter.swift) needs. They are part of
// libVLC inside MobileVLCKit; VLCKit just does not publish their headers. Signatures as in libVLC 3.0
// (vlc/libvlc_media.h, vlc/libvlc_media_player.h).

#include <stdint.h>

typedef struct libvlc_instance_t libvlc_instance_t;
typedef struct libvlc_media_t libvlc_media_t;
typedef struct libvlc_media_player_t libvlc_media_player_t;

libvlc_media_t *libvlc_media_new_location(libvlc_instance_t *p_instance, const char *psz_mrl);
void libvlc_media_add_option(libvlc_media_t *p_md, const char *psz_options);
void libvlc_media_release(libvlc_media_t *p_md);

libvlc_media_player_t *libvlc_media_player_new_from_media(libvlc_media_t *p_md);
void libvlc_media_player_release(libvlc_media_player_t *p_mi);
int libvlc_media_player_play(libvlc_media_player_t *p_mi);
void libvlc_media_player_stop(libvlc_media_player_t *p_mi);
float libvlc_media_player_get_position(libvlc_media_player_t *p_mi);
void libvlc_media_player_set_position(libvlc_media_player_t *p_mi, float f_pos);
int64_t libvlc_media_player_get_length(libvlc_media_player_t *p_mi);

typedef void *(*libvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*libvlc_video_unlock_cb)(void *opaque, void *picture, void *const *planes);
typedef void (*libvlc_video_display_cb)(void *opaque, void *picture);
typedef unsigned (*libvlc_video_format_cb)(void **opaque, char *chroma, unsigned *width, unsigned *height,
                                           unsigned *pitches, unsigned *lines);
typedef void (*libvlc_video_cleanup_cb)(void *opaque);

void libvlc_video_set_callbacks(libvlc_media_player_t *mp, libvlc_video_lock_cb lock, libvlc_video_unlock_cb unlock,
                                libvlc_video_display_cb display, void *opaque);
void libvlc_video_set_format_callbacks(libvlc_media_player_t *mp, libvlc_video_format_cb setup,
                                       libvlc_video_cleanup_cb cleanup);
