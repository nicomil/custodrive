#define main openhdd_copy_embedded_main
#include "../Sources/NTFSWrite/OpenHDDCopy.c"
#undef main

#include <sys/wait.h>

int main(int argc, char **argv)
{
    if (argc != 3) return 2;
    quarantine_path = argv[2];
    int image = open(argv[1], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (image < 0 || fstat(image, &info) || !S_ISREG(info.st_mode) ||
        quarantine_status(image, (uint64_t)info.st_size) != 0) return 1;
    pid_t child = fork();
    if (child < 0) return 1;
    if (!child) {
        int directory = -1;
        char name[80];
        if (quarantine_begin(image, (uint64_t)info.st_size, &directory,
                             name, sizeof(name))) _exit(1);
        _exit(0); /* Marker must survive without normal process cleanup. */
    }
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) ||
        WEXITSTATUS(status) ||
        quarantine_status(image, (uint64_t)info.st_size) != 1) return 1;
    int directory = -1;
    char name[80];
    if (quarantine_begin(image, (uint64_t)info.st_size, &directory,
                         name, sizeof(name)) != EINPROGRESS) return 1;
    if (directory >= 0 && close(directory)) return 1;
    directory = quarantine_directory(0);
    if (directory < 0 || quarantine_name(image, (uint64_t)info.st_size,
                                         name, sizeof(name)) ||
        quarantine_clear(directory, name) || close(directory) ||
        quarantine_status(image, (uint64_t)info.st_size) != 0 ||
        close(image)) return 1;
    puts("PASS: local safety marker survives process exit and blocks retry");
    return 0;
}
