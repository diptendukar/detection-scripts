// Fake java.exe for exercising Detect-Jdk8392044.ps1 decision logic on any
// hardware. Emits the same shapes HotSpot prints for
// -XshowSettings:properties, -Xlog:os+cpu and -XX:+PrintFlagsFinal.
//
// Environment knobs:
//   FAKE_VER        java.version            (default 17.0.9)
//   FAKE_VM         java.vm.name            (default OpenJDK 64-Bit Server VM)
//   FAKE_ARCH       os.arch                 (default amd64)
//   FAKE_FEATURES   CPU feature list        (default includes avx512_vbmi, avx512bw)
//   FAKE_NOCPULOG   if set, omit the os,cpu log line
//
// C# 5 so it builds with the .NET Framework csc behind Windows PowerShell's Add-Type.
using System;

public static class FakeJava
{
    static string Env(string name, string def)
    {
        string v = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrEmpty(v) ? def : v;
    }

    public static int Main(string[] args)
    {
        string ver = Env("FAKE_VER", "17.0.9");
        string vm = Env("FAKE_VM", "OpenJDK 64-Bit Server VM");
        string arch = Env("FAKE_ARCH", "amd64");
        string feat = Env("FAKE_FEATURES",
            "cx8, cmov, avx, avx2, avx512f, avx512dq, avx512cd, avx512bw, avx512vl, avx512_vbmi2, avx512_vbmi");

        foreach (string a in args)
        {
            if (a == "-XshowSettings:properties")
            {
                Console.Error.WriteLine("Property settings:");
                Console.Error.WriteLine("    java.version = " + ver);
                Console.Error.WriteLine("    java.vm.name = " + vm);
                Console.Error.WriteLine("    os.arch = " + arch);
                Console.Error.WriteLine("");
                Console.Error.WriteLine("openjdk version \"" + ver + "\"");
                return 0;
            }
        }

        int avx = 3;
        string b64 = "true", comp = "true", stop = "4", dis = "";
        foreach (string a in args)
        {
            if (a.StartsWith("-XX:UseAVX=")) avx = int.Parse(a.Substring(11));
            else if (a == "-XX:-UseBASE64Intrinsics") b64 = "false";
            else if (a == "-XX:+UseBASE64Intrinsics") b64 = "true";
            else if (a == "-Xint") comp = "false";
            else if (a.StartsWith("-XX:TieredStopAtLevel=")) stop = a.Substring(22);
            else if (a.StartsWith("-XX:DisableIntrinsic=")) dis = a.Substring(21);
        }
        int max = feat.Contains("avx512f") ? 3 : 2;
        if (avx > max) avx = max;
        if (avx < 3) feat = "cx8, cmov, avx, avx2";

        if (Environment.GetEnvironmentVariable("FAKE_NOCPULOG") == null)
        {
            Console.Out.WriteLine("[0.010s][info][os,cpu] CPU: total 8 (initial active 8) family 6 model 106 stepping 6 microcode 0xd0003a5, " + feat);
        }
        Console.Out.WriteLine("     intx UseAVX                                   = " + avx + "                                         {ARCH product} {default}");
        Console.Out.WriteLine("     bool UseBASE64Intrinsics                      = " + b64 + "                                      {product} {default}");
        Console.Out.WriteLine("     bool UseCompiler                              = " + comp + "                                      {product} {default}");
        Console.Out.WriteLine("     bool TieredCompilation                        = true                                      {product} {default}");
        Console.Out.WriteLine("     intx TieredStopAtLevel                        = " + stop + "                                         {product} {default}");
        Console.Out.WriteLine("    ccstrlist DisableIntrinsic                     = " + dis + "                                          {diagnostic} {default}");
        Console.Error.WriteLine("openjdk version \"" + ver + "\"");
        return 0;
    }
}
