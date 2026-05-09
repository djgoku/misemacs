/* relocate-init.c — runtime-prefix shim for conda's libenchant.
 *
 * conda's libenchant ships with --enable-relocatable, but gnulib's
 * find_shared_library_fullname() is implemented only for Linux/Cygwin —
 * there's no macOS dladdr path. So the auto-detect never fires and
 * relocate() returns the compile-time prefix (conda's install dir).
 *
 * We close that gap with a constructor that:
 *   1. Resolves jinx-mod.dylib's runtime path via dladdr.
 *   2. Walks up to the enclosing .app bundle's Contents/.
 *   3. Calls libenchant's public enchant_set_prefix_dir() with
 *      Contents/Frameworks — that's the runtime install prefix that
 *      maps to libenchant's compile-time conda install dir.
 *
 * enchant_set_prefix_dir is exported by libenchant and internally calls
 * gnulib's set_relocation_prefix(INSTALLPREFIX, new_prefix), so we don't
 * need to know what conda compiled INSTALLPREFIX as.
 *
 * Bundle layout the constructor implies:
 *   <bundle>/Contents/Frameworks/lib/libenchant-2.2.dylib   (jinx-mod links this)
 *   <bundle>/Contents/Frameworks/lib/enchant-2/*.so         (provider plugins)
 *   <bundle>/Contents/Frameworks/share/enchant-2/*.config   (provider config)
 *
 * libenchant's relocate() then maps its compile-time
 *   <conda-install>/lib/enchant-2  ->  <bundle>/Contents/Frameworks/lib/enchant-2
 * which is where bundle-app.sh deposits AppleSpell.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void enchant_set_prefix_dir(const char *new_prefix);

static void enchant_relocate_init(void) __attribute__((constructor));

static void enchant_relocate_init(void) {
    Dl_info info;
    if (!dladdr((const void *)enchant_relocate_init, &info)
        || info.dli_fname == NULL) {
        return;
    }

    char path[4096];
    size_t n = strlen(info.dli_fname);
    if (n >= sizeof(path)) {
        return;
    }
    memcpy(path, info.dli_fname, n + 1);
    for (int i = 0; i < 3; ++i) {
        char *slash = strrchr(path, '/');
        if (slash == NULL) {
            return;
        }
        *slash = '\0';
    }

    /* path is now <bundle>/Contents — append /Frameworks. */
    char runtime_prefix[4096];
    int written = snprintf(runtime_prefix, sizeof(runtime_prefix),
                           "%s/Frameworks", path);
    if (written < 0 || (size_t)written >= sizeof(runtime_prefix)) {
        return;
    }

    enchant_set_prefix_dir(runtime_prefix);
}
