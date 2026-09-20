using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

internal static class Program
{
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    public static int Main(string[] args)
    {
        try
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string pathFile = Path.Combine(baseDir, "real-codex-path.txt");

            if (!File.Exists(pathFile))
            {
                Console.Error.WriteLine("Codex provider facade: missing " + pathFile);
                return 127;
            }

            string realCodex = File.ReadAllText(pathFile).Trim();
            if (String.IsNullOrWhiteSpace(realCodex) || !File.Exists(realCodex))
            {
                Console.Error.WriteLine("Codex provider facade: real Codex executable was not found: " + realCodex);
                return 127;
            }

            bool appServer = false;
            foreach (string arg in args)
            {
                if (String.Equals(arg, "app-server", StringComparison.OrdinalIgnoreCase))
                {
                    appServer = true;
                    break;
                }
            }

            if (!appServer)
            {
                string[] effectiveArgs = RewriteCliArgsIfNeeded(args);
                return RunPassThrough(realCodex, effectiveArgs);
            }

            return RunAppServerProxy(realCodex, args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Codex provider facade failed: " + ex.Message);
            return 126;
        }
    }

    private static string[] RewriteCliArgsIfNeeded(string[] args)
    {
        if (args == null)
        {
            args = new string[0];
        }

        bool hasExplicitProvider = false;

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i] ?? "";

            // Respect any provider the caller supplied explicitly.
            if (arg.IndexOf("model_provider=", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                hasExplicitProvider = true;
                break;
            }

            if ((String.Equals(arg, "-c", StringComparison.OrdinalIgnoreCase) ||
                 String.Equals(arg, "--config", StringComparison.OrdinalIgnoreCase)) &&
                i + 1 < args.Length &&
                (args[i + 1] ?? "").IndexOf("model_provider=", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                hasExplicitProvider = true;
                break;
            }
        }

        if (hasExplicitProvider)
        {
            return args;
        }

        string provider = ReadCurrentProvider();
        if (String.IsNullOrWhiteSpace(provider))
        {
            return args;
        }

        // Put the provider into Codex's SessionFlags layer. This is the key
        // difference from merely having model_provider in config.toml:
        // internal /resume then treats the provider as an explicit resume
        // override instead of restoring the provider persisted with the thread.
        List<string> rewritten = new List<string>();
        rewritten.Add("-c");
        rewritten.Add("model_provider=" + ((char)34) + provider + ((char)34));
        rewritten.AddRange(args);
        return rewritten.ToArray();
    }

    private static int RunPassThrough(string executable, string[] args)
    {
        using (Process p = new Process())
        {
            p.StartInfo = BuildStartInfo(executable, args, false);
            if (!p.Start())
            {
                return 126;
            }
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    private static int RunAppServerProxy(string executable, string[] args)
    {
        using (Process p = new Process())
        {
            p.StartInfo = BuildStartInfo(executable, args, true);

            if (!p.Start())
            {
                return 126;
            }

            Thread stdout = new Thread(delegate()
            {
                try
                {
                    string line;
                    while ((line = p.StandardOutput.ReadLine()) != null)
                    {
                        Console.Out.WriteLine(line);
                        Console.Out.Flush();
                    }
                }
                catch { }
            });
            stdout.IsBackground = true;

            Thread stderr = new Thread(delegate()
            {
                try
                {
                    string line;
                    while ((line = p.StandardError.ReadLine()) != null)
                    {
                        Console.Error.WriteLine(line);
                        Console.Error.Flush();
                    }
                }
                catch { }
            });
            stderr.IsBackground = true;

            stdout.Start();
            stderr.Start();

            try
            {
                string line;
                while ((line = Console.In.ReadLine()) != null)
                {
                    string rewritten = RewriteRequestIfNeeded(line);
                    p.StandardInput.WriteLine(rewritten);
                    p.StandardInput.Flush();
                }
            }
            catch (IOException)
            {
                // The extension or child process closed its side of the pipe.
            }
            finally
            {
                try { p.StandardInput.Close(); } catch { }
            }

            p.WaitForExit();

            try { stdout.Join(1500); } catch { }
            try { stderr.Join(1500); } catch { }

            return p.ExitCode;
        }
    }

    private static ProcessStartInfo BuildStartInfo(string executable, string[] args, bool redirect)
    {
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = executable;
        psi.Arguments = JoinArguments(args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;

        if (redirect)
        {
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
        }

        return psi;
    }

    private static string RewriteRequestIfNeeded(string line)
    {
        if (String.IsNullOrWhiteSpace(line))
        {
            return line;
        }

        try
        {
            object decoded = Json.DeserializeObject(line);
            Dictionary<string, object> message = decoded as Dictionary<string, object>;
            if (message == null)
            {
                return line;
            }

            object methodValue;
            if (!message.TryGetValue("method", out methodValue) || methodValue == null)
            {
                return line;
            }

            string method = Convert.ToString(methodValue);
            Dictionary<string, object> parameters = null;
            object paramsValue;
            if (message.TryGetValue("params", out paramsValue))
            {
                parameters = paramsValue as Dictionary<string, object>;
            }

            if (parameters == null)
            {
                parameters = new Dictionary<string, object>();
                message["params"] = parameters;
            }

            if (String.Equals(method, "thread/list", StringComparison.Ordinal))
            {
                // The app-server protocol defines an empty modelProviders list as
                // "include all providers". This keeps subscription-created and
                // API-created conversations visible together in VS Code even
                // while the currently routed provider changes.
                parameters["modelProviders"] = new object[0];
                return Json.Serialize(message);
            }

            if (!String.Equals(method, "thread/resume", StringComparison.Ordinal) &&
                !String.Equals(method, "thread/start", StringComparison.Ordinal))
            {
                return line;
            }

            object existing;
            if (parameters.TryGetValue("modelProvider", out existing) &&
                existing != null &&
                !String.IsNullOrWhiteSpace(Convert.ToString(existing)))
            {
                // Respect an explicit choice made by the extension/client.
                return line;
            }

            string provider = ReadCurrentProvider();
            if (String.IsNullOrWhiteSpace(provider))
            {
                return line;
            }

            parameters["modelProvider"] = provider;
            return Json.Serialize(message);
        }
        catch
        {
            // Never break the app-server protocol merely because a message was
            // not JSON or used a future protocol shape.
            return line;
        }
    }

    private static string ReadCurrentProvider()
    {
        string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (String.IsNullOrWhiteSpace(codexHome))
        {
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            codexHome = Path.Combine(profile, ".codex");
        }

        string config = Path.Combine(codexHome, "config.toml");
        if (!File.Exists(config))
        {
            return "openai";
        }

        foreach (string raw in File.ReadLines(config))
        {
            string line = raw.Trim();

            // Only read top-level configuration. Once a table begins, stop.
            if (line.StartsWith("["))
            {
                break;
            }

            Match m = Regex.Match(
                raw,
                "^\\s*model_provider\\s*=\\s*[\"']([^\"']+)[\"']",
                RegexOptions.IgnoreCase
            );

            if (m.Success)
            {
                return m.Groups[1].Value;
            }
        }

        return "openai";
    }

    private static string JoinArguments(string[] args)
    {
        if (args == null || args.Length == 0)
        {
            return "";
        }

        string[] quoted = new string[args.Length];
        for (int i = 0; i < args.Length; i++)
        {
            quoted[i] = QuoteArgument(args[i] ?? "");
        }
        return String.Join(" ", quoted);
    }

    // Windows command-line quoting compatible with CommandLineToArgvW.
    private static string QuoteArgument(string arg)
    {
        if (arg.Length > 0 &&
            arg.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return arg;
        }

        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        sb.Append('"');

        int backslashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\')
            {
                backslashes++;
                continue;
            }

            if (c == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
                continue;
            }

            if (backslashes > 0)
            {
                sb.Append('\\', backslashes);
                backslashes = 0;
            }

            sb.Append(c);
        }

        if (backslashes > 0)
        {
            sb.Append('\\', backslashes * 2);
        }

        sb.Append('"');
        return sb.ToString();
    }
}
