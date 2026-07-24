/* Demonstrates the OIS claim protocol from a normally-launched binary.
 *
 * Important: when a user runs your app directly, OIS is NOT in the
 * process chain, so OIS_* environment variables are NOT set. Your app
 * finds its own OIS state by looking in the two standard store roots.
 * Everything below degrades to a no-op when OIS never installed you. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define APP_NAME "hello-cmake"

/* Locate <store>/apps/<app>/<leaf>. Returns 1 on success. */
static int ois_state_path(const char *leaf, char *out, size_t n) {
    const char *home = getenv("HOME");
    const char *xdg  = getenv("XDG_DATA_HOME");
    char cand[1024];
    FILE *f;

    /* 1. OIS launched us and already told us where the claims file is. */
    if (!strcmp(leaf, "claims")) {
        const char *c = getenv("OIS_CLAIMS");
        if (c) { snprintf(out, n, "%s", c); return 1; }
    }
    /* 2. explicit store root, if the user set one */
    {
        const char *root = getenv("OIS_ROOT");
        if (root && *root) {
            snprintf(cand, sizeof cand, "%s/apps/%s/%s", root, APP_NAME, leaf);
            if ((f = fopen(cand, "r"))) { fclose(f); snprintf(out, n, "%s", cand); return 1; }
        }
    }
    /* 3. user-scope store */
    if (xdg && *xdg)
        snprintf(cand, sizeof cand, "%s/ois/apps/%s/%s", xdg, APP_NAME, leaf);
    else if (home)
        snprintf(cand, sizeof cand, "%s/.local/share/ois/apps/%s/%s", home, APP_NAME, leaf);
    else
        cand[0] = '\0';
    if (cand[0] && (f = fopen(cand, "r"))) { fclose(f); snprintf(out, n, "%s", cand); return 1; }

    /* 4. system-scope store */
    snprintf(cand, sizeof cand, "/usr/local/lib/ois/apps/%s/%s", APP_NAME, leaf);
    if ((f = fopen(cand, "r"))) { fclose(f); snprintf(out, n, "%s", cand); return 1; }
    return 0;
}

/* Read one KEY from the env block OIS wrote for us. */
static int ois_get(const char *key, char *out, size_t n) {
    char envp[1024], line[1024];
    FILE *f;
    size_t klen = strlen(key);
    if (!ois_state_path("env", envp, sizeof envp)) return 0;
    if (!(f = fopen(envp, "r"))) return 0;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, klen) || line[klen] != '=') continue;
        line[strcspn(line, "\r\n")] = '\0';
        snprintf(out, n, "%s", line + klen + 1);
        fclose(f);
        return out[0] != '\0';
    }
    fclose(f);
    return 0;
}

/* Register a path we created so `uninstall` cleans it up.
   One fprintf + fclose == one write(2) under PIPE_BUF == atomic. */
static void ois_claim(const char *path, const char *policy) {
    char cp[1024];
    FILE *f;
    if (!ois_state_path("claims", cp, sizeof cp)) return;
    if (!(f = fopen(cp, "a"))) return;
    fprintf(f, "file\t%s\t%s\n", path, policy);
    fclose(f);
}

int main(void) {
    char cfg[1024], ver[128], path[1200];
    printf("%s\n", GREETING);

    if (ois_get("OIS_APP_VERSION", ver, sizeof ver))
        printf("installed by OIS, version %s\n", ver);
    else
        printf("not installed by OIS (running from a build tree?)\n");

    if (ois_get("OIS_CONFIG_DIR", cfg, sizeof cfg)) {
        printf("config dir: %s\n", cfg);
        snprintf(path, sizeof path, "%s/settings.ini", cfg);
        ois_claim(path, "keep");     /* OIS will now track and clean it */
    }
    return 0;
}
