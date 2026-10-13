// TrayGlass.exe - helper for the Windows 11 System Tray Styler for Claude skin (created by Ryan Peddigrew).
//  - Moves the bubble with the auto-hide taskbar on every frame of its slide (WinEvent hook on the taskbar
//    window), so tray and taskbar travel together; when the taskbar is hidden the bubble is below the screen.
//    No polling: idle CPU is zero.
//  - Gives the skin window the same glass as the taskbar dock: blur, 12 px corners, no Windows border
//    (the skin draws the dock's top highlight itself).
//  - "TrayGlass.exe calendar" sends Win+Alt+D (opens the date/calendar flyout) for the clock click.
// Usage (from the skin): TrayGlass.exe "<skin .ini path>" "<config name>" [rightGap px] [topOffset px]
//        TrayGlass.exe calendar
// Single instance. Build (install.ps1 does this): C:WindowsMicrosoft.NETFramework644.0.30319c.exe /target:winexe /out:TrayGlass.exe TrayGlass.cs
using System;
using System.Runtime.InteropServices;
using System.Threading;

static class TrayGlass
{
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct CDS { public IntPtr dw; public int cb; public IntPtr lp; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w, l; public uint t; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct ACCENT { public int State, Flags, Color, Anim; }
    [StructLayout(LayoutKind.Sequential)] struct WCAD { public int Attr; public IntPtr Data; public int Size; }
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time);
    delegate void TimerProc(IntPtr h, uint m, IntPtr id, uint t);

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, ref CDS l, uint f, uint t, out IntPtr r);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint a, uint b, IntPtr mod, WinEventProc p, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SetTimer(IntPtr h, IntPtr id, uint ms, TimerProc p);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr h, ref WCAD d);
    [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    // Set from the command line: the skin window title is its .ini path.
    static string Skin = "", Config = "";
    // The dock's glass starts this many physical px below the top of the taskbar window (measured on screen).
    static int DockTop = 4;
    // Gap between the bubble's right edge and the taskbar's right edge, physical px.
    static int RightGap = 6;
    const int Radius = 12; // dock corner radius, physical px (measured)
    static WinEventProc proc;
    static TimerProc tick;
    static IntPtr tray = IntPtr.Zero, hook = IntPtr.Zero, skin = IntPtr.Zero;
    static int lastW = -1, lastH = -1;

    static bool Bang(string s)
    {
        IntPtr h = FindWindow("DummyRainWClass", null);
        if (h == IntPtr.Zero) return false;
        CDS d = new CDS(); d.dw = (IntPtr)1; d.cb = (s.Length + 1) * 2; d.lp = Marshal.StringToHGlobalUni(s);
        IntPtr r; IntPtr ok = SendMessageTimeout(h, 0x4A, IntPtr.Zero, ref d, 2, 3000, out r);
        Marshal.FreeHGlobal(d.lp);
        return ok != IntPtr.Zero;
    }

    // Blur behind (tint comes from the skin), no DWM rounding/border, 12 px rounded clip like the dock.
    static void Glass(bool force)
    {
        skin = FindWindow("RainmeterMeterWindow", Skin); // (a null class does not find it)
        if (skin == IntPtr.Zero) return;
        RECT r; GetWindowRect(skin, out r);
        int w = r.R - r.L, h = r.B - r.T;
        if (!force && w == lastW && h == lastH) return;
        lastW = w; lastH = h;
        ACCENT a = new ACCENT(); a.State = 3; // ACCENT_ENABLE_BLURBEHIND
        int sz = Marshal.SizeOf(a); IntPtr p = Marshal.AllocHGlobal(sz); Marshal.StructureToPtr(a, p, false);
        WCAD d = new WCAD(); d.Attr = 19; d.Data = p; d.Size = sz; // WCA_ACCENT_POLICY
        SetWindowCompositionAttribute(skin, ref d); Marshal.FreeHGlobal(p);
        int noRound = 1; DwmSetWindowAttribute(skin, 33, ref noRound, 4);       // DWMWCP_DONOTROUND
        int noBorder = unchecked((int)0xFFFFFFFE); DwmSetWindowAttribute(skin, 34, ref noBorder, 4); // DWMWA_BORDER_COLOR = none
        SetWindowRgn(skin, CreateRoundRectRgn(0, 0, w + 1, h + 1, Radius * 2, Radius * 2), true);
    }

    // Put the bubble's top level with the dock's top, wherever the taskbar is in its slide.
    static void Follow()
    {
        if (skin == IntPtr.Zero) { Glass(true); if (skin == IntPtr.Zero) return; }
        RECT t, s;
        if (!GetWindowRect(tray, out t) || !GetWindowRect(skin, out s)) { skin = IntPtr.Zero; return; }
        int y = t.T + DockTop;
        int x = t.R - RightGap - (s.R - s.L);
        // HWND_TOPMOST each time: the taskbar raises itself when it shows, and the bubble must stay on top of it.
        SetWindowPos(skin, (IntPtr)(-1), x, y, 0, 0, 0x0001 | 0x0010 | 0x0200); // NOSIZE|NOACTIVATE|NOOWNERZORDER
    }

    static void Hook()
    {
        if (hook != IntPtr.Zero) UnhookWinEvent(hook);
        tray = FindWindow("Shell_TrayWnd", null);
        uint pid; GetWindowThreadProcessId(tray, out pid);
        hook = SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, proc, pid, 0, 0); // EVENT_OBJECT_LOCATIONCHANGE, out of context
    }

    static void Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "calendar")
        {
            keybd_event(0x5B, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x44, 0, 0, UIntPtr.Zero);
            keybd_event(0x44, 0, 2, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); keybd_event(0x5B, 0, 2, UIntPtr.Zero);
            return;
        }
        if (args.Length < 2) return; // started by hand without the skin's arguments: nothing to do
        Skin = args[0]; Config = args[1];
        int n;
        if (args.Length > 2 && int.TryParse(args[2], out n)) RightGap = n;
        if (args.Length > 3 && int.TryParse(args[3], out n)) DockTop = n;
        bool created; Mutex mutex = new Mutex(true, @"Local\TrayStylerForClaudeGlass", out created);
        SetProcessDPIAware();
        // Already running (the skin was refreshed and launched us again): just re-apply glass and position.
        if (!created) { tray = FindWindow("Shell_TrayWnd", null); Glass(true); Follow(); return; }
        proc = delegate (IntPtr hk, uint ev, IntPtr hwnd, int obj, int child, uint th, uint time) { if (obj == 0 && hwnd == tray) Follow(); };
        tick = delegate (IntPtr h, uint m, IntPtr id, uint t)
        {
            // Explorer restarted: re-hook. Rainmeter gone: quit (the skin restarts us). Skin refreshed: re-apply glass.
            IntPtr now = FindWindow("Shell_TrayWnd", null);
            if (now != IntPtr.Zero && now != tray) Hook();
            if (FindWindow("DummyRainWClass", null) == IntPtr.Zero) Environment.Exit(0);
            Glass(false);
            Follow();
        };
        Hook();
        Bang("[!Show \"" + Config + "\"]");
        Glass(true);
        Follow();
        SetTimer(IntPtr.Zero, IntPtr.Zero, 30000, tick);
        MSG msg; while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) DispatchMessage(ref msg);
        GC.KeepAlive(mutex);
    }
}
