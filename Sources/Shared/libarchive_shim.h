// Minimal declarations for the system libarchive (/usr/lib/libarchive.2.dylib).
// The macOS SDK ships the .tbd but not the headers, so we declare what we use.
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data(struct archive *, void *buffer, size_t length);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);

// bzip2 (/usr/lib/libbz2), for bzip2-compressed disk images.
int BZ2_bzBuffToBuffDecompress(char *dest, unsigned int *destLen, char *source,
                               unsigned int sourceLen, int small, int verbosity);
