#requires -Version 5.1

# Windows Job Objects: workers entram suspensos no grupo antes de executar codigo.
# https://learn.microsoft.com/windows/win32/procthread/job-objects
function Initialize-BackupProcessSupport {
    if ('VMExportBackup.ProcessJob' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace VMExportBackup {
    public sealed class ProcessJob : IDisposable {
        IntPtr handle;
        public string Name { get; private set; }
        [StructLayout(LayoutKind.Sequential)] struct FileTime { public uint Low, High; }
        [StructLayout(LayoutKind.Sequential)] struct FileInfo {
            public uint Attributes; public FileTime Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)] struct Limits {
            public long ProcessTime, JobTime; public uint Flags; public UIntPtr MinWorking, MaxWorking;
            public uint ActiveLimit; public UIntPtr Affinity; public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IO { public ulong A,B,C,D,E,F; }
        [StructLayout(LayoutKind.Sequential)] struct Extended {
            public Limits Basic; public IO Counters; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
        }
        [StructLayout(LayoutKind.Sequential)] struct Accounting {
            public long User, Kernel, PeriodUser, PeriodKernel;
            public uint Faults, Total, Active, Terminated;
        }
        [StructLayout(LayoutKind.Sequential)] struct Security {
            public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
            public int Size; public string Reserved, Desktop, Title;
            public uint X,Y,XSize,YSize,XChars,YChars,Fill,Flags; public short Show, ReservedSize;
            public IntPtr ReservedBytes, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process, Thread; public uint Id, ThreadId; }
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int info, ref Extended value, uint length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int info, out Accounting value, uint length, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr value);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr file, out FileInfo info);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr CreateFile(string path, uint access, uint share, ref Security security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcess(string app, StringBuilder args, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string directory, ref Startup startup, out ProcessInfo process);
        static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }

        public static ProcessJob ForRepository(IntPtr lockFile) {
            FileInfo file; Check(GetFileInformationByHandle(lockFile, out file));
            string identity = file.Volume.ToString("X8") + file.IndexHigh.ToString("X8") + file.IndexLow.ToString("X8");
            string name;
            using (SHA256 sha = SHA256.Create()) { name = "Global\\VMExportBackup-" + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(identity))).Replace("-", ""); }
            ProcessJob job = new ProcessJob(); job.Name = name;
            job.handle = CreateJobObject(IntPtr.Zero, name); Check(job.handle != IntPtr.Zero);
            try {
                // Um dono anterior pode ter morrido antes da ultima thread filha.
                // Sob o lock de arquivo, drenamos o grupo antigo antes de mutar dados.
                job.Stop(10000);
                Extended info = new Extended(); info.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE, sem breakaway
                Check(SetInformationJobObject(job.handle, 9, ref info, (uint)Marshal.SizeOf(typeof(Extended))));
                return job;
            } catch { job.Dispose(); throw; }
        }
        public uint ActiveProcesses {
            get { Accounting info; Check(QueryInformationJobObject(handle, 1, out info, (uint)Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero)); return info.Active; }
        }
        public void Stop(int timeoutMilliseconds) {
            if (ActiveProcesses != 0) Check(TerminateJobObject(handle, 1));
            Stopwatch watch = Stopwatch.StartNew();
            while (ActiveProcesses != 0) {
                if (watch.ElapsedMilliseconds >= timeoutMilliseconds) throw new TimeoutException("A arvore de workers ainda esta ativa; repositorio nao pode ser reutilizado.");
                Thread.Sleep(20);
            }
        }
        static IntPtr OpenIO(string path, uint access, uint creation) {
            Security security = new Security(); security.Length = Marshal.SizeOf(typeof(Security)); security.Inherit = true;
            IntPtr value = CreateFile(path, access, 3, ref security, creation, 0x80, IntPtr.Zero);
            Check(value != new IntPtr(-1)); return value;
        }
        public Process Start(string executable, string arguments, string stdout, string stderr) {
            if (ActiveProcesses != 0) throw new InvalidOperationException("Existem workers ativos no grupo.");
            IntPtr output = IntPtr.Zero, error = IntPtr.Zero, input = IntPtr.Zero;
            ProcessInfo info = new ProcessInfo(); bool resumed = false;
            try {
                output = OpenIO(stdout, 0x40000000, 2); error = OpenIO(stderr, 0x40000000, 2); input = OpenIO("NUL", 0x80000000, 3);
                Startup startup = new Startup(); startup.Size = Marshal.SizeOf(typeof(Startup)); startup.Flags = 0x100;
                startup.Input = input; startup.Output = output; startup.Error = error;
                StringBuilder command = new StringBuilder("\"" + executable + "\" " + arguments);
                Check(CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, true, 0x08000004, IntPtr.Zero, null, ref startup, out info));
                Check(AssignProcessToJobObject(handle, info.Process));
                Process process = Process.GetProcessById((int)info.Id);
                IntPtr cached = process.Handle; // Preserva ExitCode mesmo para processos muito curtos.
                if (ResumeThread(info.Thread) == UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                resumed = true; return process;
            } finally {
                if (!resumed && info.Process != IntPtr.Zero) TerminateProcess(info.Process, 1);
                if (info.Thread != IntPtr.Zero) CloseHandle(info.Thread);
                if (info.Process != IntPtr.Zero) CloseHandle(info.Process);
                if (input != IntPtr.Zero) CloseHandle(input);
                if (output != IntPtr.Zero) CloseHandle(output);
                if (error != IntPtr.Zero) CloseHandle(error);
            }
        }
        public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
    }
}
'@ -ErrorAction Stop
}

function Start-BackupJobProcess {
    param([Parameter(Mandatory = $true)]$Job, [string]$FilePath, [string]$ArgumentString, [string]$StdOutPath, [string]$StdErrPath)
    $executable = (Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop).Source
    return $Job.Start($executable, $ArgumentString, $StdOutPath, $StdErrPath)
}
