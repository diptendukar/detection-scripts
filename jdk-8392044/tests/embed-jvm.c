/* Holds libjvm.so mapped in a process that is not java, the way an embedded
 * JVM (JNI host, database, app server launcher) looks in /proc/<pid>/maps. */
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 2 || !dlopen(argv[1], RTLD_NOW)) {
        fprintf(stderr, "dlopen failed: %s\n", argc < 2 ? "usage: embed-jvm LIBJVM" : dlerror());
        return 1;
    }
    pause();
    return 0;
}
