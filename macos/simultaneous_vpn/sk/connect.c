/* Fixed, argument-free target for the restricted sudo rule. No setuid bit. */
#include <stdio.h>
#define SK_BASE "/Library/PrivilegedHelperTools/local.sk-vpn"
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1) {
        fputs("This launcher accepts no arguments. Run sk.\n", stderr);
        return 64;
    }
    if (geteuid() != 0) {
        fputs("This launcher must be invoked through the restricted sudo rule.\n", stderr);
        return 77;
    }
    umask(077);
    if (chdir("/") != 0) return 71;
    for (int fd = getdtablesize() - 1; fd >= 3; --fd) close(fd);
    char *const env[] = {
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C",
        "GNUTLS_SYSTEM_PRIORITY_FILE=" SK_BASE "/runtime/gnutls.conf",
        "P11_KIT_NO_USER_CONFIG=1", NULL
    };
    /* Deny user-writable Homebrew configuration/modules as well as libraries.
       All executable dependencies have been copied into the protected runtime. */
    char *const args[] = {
        "/usr/bin/sandbox-exec", "-p",
        "(version 1)(allow default)"
        "(deny file-read* file-write* (subpath \"/opt/homebrew\")"
        " (subpath \"/usr/local\") (subpath \"/Users\"))",
        SK_BASE "/runtime/openconnect",
        "--config=" SK_BASE "/openconnect.conf", "--passwd-on-stdin", "--no-system-trust",
        "--script=" SK_BASE "/runtime/vpnc-script",
        "--csd-wrapper=/usr/bin/false", "vpn.skoltech.ru", NULL
    };
    execve(args[0], args, env);
    perror("Unable to start the VPN launcher");
    return 71;
}
