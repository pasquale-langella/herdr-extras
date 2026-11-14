// Tiny console trampoline so Herdr starts an .exe (not python/cmd), which it
// attaches to directly instead of wrapping in pwsh -Command.
// Build: csc /nologo /out:cursor-herdr.exe cursor-herdr-launch.cs
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

class CursorHerdrLaunch
{
    static int Main(string[] args)
    {
        string here = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        if (string.IsNullOrEmpty(here))
        {
            Console.Error.WriteLine("cannot resolve cursor-herdr.exe directory");
            return 1;
        }

        string script = Path.Combine(here, "cursor-herdr.py");
        if (!File.Exists(script))
        {
            Console.Error.WriteLine("cursor-herdr.py not found next to cursor-herdr.exe");
            return 1;
        }

        string python = FindPython();
        if (python == null)
        {
            Console.Error.WriteLine("python.exe not found (install Python 3 or set CURSOR_HERDR_PYTHON)");
            return 1;
        }

        StringBuilder arg = new StringBuilder();
        arg.Append("-u ");
        arg.Append('"').Append(script).Append('"');
        for (int i = 0; i < args.Length; i++)
        {
            arg.Append(' ');
            arg.Append(Quote(args[i]));
        }

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = python;
        psi.Arguments = arg.ToString();
        psi.UseShellExecute = false;

        Process p = Process.Start(psi);
        if (p == null) return 1;
        p.WaitForExit();
        int code = p.ExitCode;
        p.Dispose();
        return code;
    }

    static string Quote(string s)
    {
        if (s.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return s;
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }

    static string FindPython()
    {
        string env = Environment.GetEnvironmentVariable("CURSOR_HERDR_PYTHON");
        if (!string.IsNullOrEmpty(env) && File.Exists(env)) return env;

        string local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (local == null) local = "";
        string[] rels = new string[] {
            @"Programs\Python\Python313\python.exe",
            @"Programs\Python\Python312\python.exe",
            @"Programs\Python\Python311\python.exe",
            @"Programs\Python\Python310\python.exe",
        };
        for (int i = 0; i < rels.Length; i++)
        {
            string c = Path.Combine(local, rels[i]);
            if (File.Exists(c) && new FileInfo(c).Length > 0) return c;
        }

        return "python";
    }
}
