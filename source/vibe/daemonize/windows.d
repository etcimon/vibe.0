/**
*    Implementation of cross-platform daemon API for Windows platform.
*    
*   Copyright: © 2013-2014 Anton Gushcha
*   License: Subject to the terms of the MIT license, as written in the included LICENSE file.
*   Authors: NCrashed <ncrashed@gmail.com>
*/
module vibe.daemonize.windows;

version(Windows):

import core.sys.windows.windows;
import core.thread;
import core.time;
import std.datetime;
import std.string;
import std.typetuple;
import std.utf;
import core.stdc.stdlib;
import std.typecons;
import std.conv;
import vibe.core.log;

public import vibe.daemonize.daemon;
public import vibe.daemonize.keymap;

/// Windows version doesn't use pid files
string defaultPidFile(string daemonName)
{
	return "";  
}

/// Windows version doesn't use lock files
string defaultLockFile(string daemonName)
{
	return "";  
}

/// Checks is $(B sig) is actually built-in
@nogc @safe bool isNativeSignal(Signal sig) pure nothrow 
{
	switch(sig)
	{
		case(Signal.Stop):           return true;
		case(Signal.Continue):       return true;
		case(Signal.Pause):          return true;
		case(Signal.Shutdown):       return true;
		case(Signal.Interrogate):    return true;
		case(Signal.NetBindAdd):     return true;
		case(Signal.NetBindDisable): return true;
		case(Signal.NetBindEnable):  return true;
		case(Signal.NetBindRemove):  return true;
		case(Signal.ParamChange):    return true;
		default: return false;
	}
}

/// Checks is $(B sig) is not actually built-in
@nogc @safe bool isCustomSignal(Signal sig) pure nothrow 
{
	return !isNativeSignal(sig);
}

/**
*    The template holds a set of functions that build, run and send signals to daemons
*    that are built with $(B Daemon) or $(B DaemonClient) template.
*
*    Truncated $(B DaemonClient) aren't able to run described daemon, only signal sending
*    and daemon uninstalling.
*/
template buildDaemon(alias DaemonInfo)
	if(isDaemon!DaemonInfo || isDaemonClient!DaemonInfo)
{
	/// Support functions
	private alias daemon = readDaemonInfo!DaemonInfo;
	
	// DaemonClient cannot run daemon
	static if(isDaemon!DaemonInfo)
	{
		/**
        *    Starts daemon that is described by $(B DaemonInfo). Daemon is implemented as
        *    windows service and auto-installed in SC manager. If you want to uninstall the
        *    service, you can use $(B uninstall) function or system call:
        *    ----------
        *    C:\Windows\System32\sc.exe delete <daemonName>
        *    ----------
        *
        *    If the service is already installed and is stopped, the function tries to start daemon.
        *    Otherwise it fails and returns EXIT_FAILURE code.
        *
        *    $(B pidFilePath), $(B lockFilePath), $(B userId) and $(B groupId)
        *    are ignored for Windows platform.
        *
        *    See_Also: $(B uninstall)
		*/
		int run(string pidFilePath = "", string lockFilePath = ""
			, int userId = -1, int groupId = -1)
		{ 
			auto maybeStatus = queryServiceStatus();
			if(maybeStatus.isNull)
			{
				serviceInstall();
				return EXIT_SUCCESS;
			} 
			else
			{            
				auto initResult = serviceInit();
				if(initResult == ServiceInitState.NotService)
				{
					auto state = maybeStatus.get.dwCurrentState;
					if(state == SERVICE_STOPPED)
					{
						serviceStart();
					}
				} else if(initResult == initResult.OtherError)
				{
					return EXIT_FAILURE;
				}
				
				return EXIT_SUCCESS;
			}
		}
		
		void install(string path) {
			serviceInstall(path);
		}
	}
	
	/**
    *   Utility function that helps to uninstall the service from the system.
    *
    *   Note: Can be used with $(B DaemonClient) template, actually you can ommit signal list for the template.
    */
	void uninstall()
	{
		auto maybeStatus = queryServiceStatus();
		if(!maybeStatus.isNull)
		{
			serviceRemove();
		}
	}
	
	/**
    *   Sends singal $(B sig) for described daemon. All signals are sent via $(B ControlService) WINAPI function.
    *    *
    *   $(B pidFilePath) is ignored for Windows platform.
    *
    *   Note: Can be used with $(B DaemonClient) template.
    */
	void sendSignal(Signal sig = Signal.Terminate, string pidFilePath = "")
	{
		auto manager = getSCManager;
		scope(exit) CloseServiceHandle(manager);
		
		auto service = getService(manager, daemon.getControlAccessFlag(sig));
		scope(exit) CloseServiceHandle(service);
		
		if(!ControlService(service, daemon.mapSignal(sig), &serviceStatus))
			throw new DaemonException(text("Failed to send signal to service ", DaemonInfo.daemonName, ". Details: ", getLastErrorDescr));
		
	}
	
	/// ditto with dynamic service name
	void sendSignalDynamic(string serviceName = null, Signal sig = Signal.Terminate, string pidFilePath = "")
	{
		auto manager = getSCManager;
		scope(exit) CloseServiceHandle(manager);
		
		auto service = OpenServiceW(manager, cast(LPWSTR)serviceName.toUTF16z, daemon.getControlAccessFlag(sig));
		if(service is null) throw new DaemonException(text("Failed to open service! ", getLastErrorDescr));
		scope(exit) CloseServiceHandle(service);
		
		if(!ControlService(service, daemon.mapSignal(sig), &serviceStatus))
			throw new DaemonException(text("Failed to send signal to service ", serviceName, ". Details: ", getLastErrorDescr));
		
	}
	
	/**
    *   Throws an exception
    */
	static class DaemonException : Exception
	{
		@trusted nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
		{
			logError("DaemonException: %s in %s at line %d", msg, file, line);
			super(msg, file, line, next);
		}
		
		@trusted nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
		{
			logError("DaemonException: %s in %s at line %d", msg, file, line);
			super(msg, file, line, next);
		}
	}
	
	private
	{
		__gshared SERVICE_STATUS serviceStatus;
		__gshared SERVICE_STATUS_HANDLE serviceStatusHandle;
		
		bool shouldExit()
		{
			return serviceStatus.dwCurrentState == SERVICE_STOPPED;
		}
		
		static if(isDaemon!DaemonInfo)
		{
			extern(System) static void serviceMain(uint argc, wchar** args) nothrow
			{
				import std.file : exists;
				try {
					import std.datetime : seconds;
					import core.thread : Thread;
					// Windows don't know anything about our runtime
					// so register the thread at druntime's thread subsystem
					// and manually run all TLS constructors and destructors
					thread_attachThis();
					Thread.getThis().name = "V|Main";
					rt_moduleTlsCtor(); 
				} catch (Throwable th) {
					scope(failure) assert(false);
				}
				scope(exit) {
					rt_moduleTlsDtor();
				}
				try {
					int code = EXIT_FAILURE;
					serviceStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
					
					serviceStatusHandle = RegisterServiceCtrlHandlerW(cast(LPWSTR)DaemonInfo.daemonName.toUTF16z, &controlHandler);
					if(serviceStatusHandle is null)
					{
						return;
					}
					
					serviceStatus.dwCurrentState = SERVICE_RUNNING;
					reportServiceStatus(SERVICE_RUNNING, NO_ERROR, 0.dur!"msecs");
					
					try code = DaemonInfo.mainFunc(&shouldExit);
					catch (Throwable ex) 
					{
						code = EXIT_FAILURE;
					}
					
					serviceStatus.dwCurrentState = SERVICE_STOPPED;
					reportServiceStatus(SERVICE_STOPPED, code, 0.dur!"msecs");
					
				}
				catch(Throwable th)
				{
				}
			}
			
			extern(System) static void controlHandler(DWORD fdwControl) nothrow
			{
				switch(fdwControl)
				{
					foreach(signal; DaemonInfo.signalMap.keys)
					{
						alias handler = DaemonInfo.signalMap.get!signal;
						
						static if(isComposition!signal)
						{
							foreach(subsignal; signal.signals)
							{
								case(daemon.mapSignal(subsignal)):
								{
									bool res = true;
									try 
									{
										serviceStatus.dwCurrentState = SERVICE_STOP_PENDING;
										reportServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 0.dur!"msecs");
										static if(__traits(compiles, handler(subsignal)))
											res = handler(subsignal);
										else
											res = handler();
										
										if(res) {
											serviceStatus.dwCurrentState = SERVICE_STOPPED;
										}
										else {
											serviceStatus.dwCurrentState = SERVICE_RUNNING;
											reportServiceStatus(SERVICE_RUNNING, NO_ERROR, 0.dur!"msecs");
										}
									}
									catch(Throwable th)
									{
									}
									return;
								}
							}
						}
						else 
						{
							case(daemon.mapSignal(signal)):
							{
								bool res = true;
								try 
								{
									serviceStatus.dwCurrentState = SERVICE_STOP_PENDING;
									reportServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 0.dur!"msecs");
									
									static if(__traits(compiles, handler(signal)))
										res = handler(signal);
									else
										res = handler();
									
									if(res) {
										serviceStatus.dwCurrentState = SERVICE_STOPPED;
										// ok
									}
									else {
										serviceStatus.dwCurrentState = SERVICE_RUNNING;
										reportServiceStatus(SERVICE_RUNNING, NO_ERROR, 0.dur!"msecs");
									}
								}
								catch(Throwable th)
								{
								}
								return;
							}
						}
					}
					case 4:
						scope(failure) assert(false);
						reportServiceStatus(serviceStatus.dwCurrentState, NO_ERROR, 0.dur!"msecs");
						break;
					default:
					{
					}
				}
			}
		}
		
		/// Wrapper for getting service manager
		SC_HANDLE getSCManager()
		{
			auto manager = OpenSCManagerW(null, null, SC_MANAGER_ALL_ACCESS);
			if(manager is null)
				throw new DaemonException(text("Failed to open SC manager!", getLastErrorDescr));
			
			return manager;
		}
		
		/// Wrapper for getting service handle
		SC_HANDLE getService(SC_HANDLE manager, DWORD accessFlags)
		{
			auto service = OpenServiceW(manager, cast(LPWSTR)DaemonInfo.daemonName.toUTF16z, accessFlags);
			if(service is null)
			{
				throw new DaemonException(text("Failed to open service! ", getLastErrorDescr));
			}
			return service;
		}
		
		static if(isDaemon!DaemonInfo)
		{
			enum ServiceInitState
			{
				ServiceIsOk, // dispatcher has run successfully 
				NotService,  // dispatcher failed with specific error
				OtherError
			}
			
			/// Performs service initialization
			/**
            *    If inner $(B StartServiceCtrlDispatcherW) fails due reason that
            *    the code is running in userspace, the function returns ServiceInitState.NotService.
            *
            *    If the code is run under SC manager, the dispatcher operates and the function
            *    returns ServiceInitState.ServiceIsOk at the end of service execution.
            *
            *    If something wrong happens, the function returns ServiceInitState.OtherError
            */
			ServiceInitState serviceInit()
			{
				SERVICE_TABLE_ENTRY[2] serviceTable;
				serviceTable[0].lpServiceName = cast(LPWSTR)DaemonInfo.daemonName.toUTF16z;
				serviceTable[0].lpServiceProc = &serviceMain;
				serviceTable[1].lpServiceName = null;
				serviceTable[1].lpServiceProc = null;
				
				if(!StartServiceCtrlDispatcherW(serviceTable.ptr))
				{
					if(GetLastError == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT)
					{
						return ServiceInitState.NotService;
					}
					else
					{
						return ServiceInitState.OtherError;
					}
				}
				
				return ServiceInitState.ServiceIsOk;
			}
		}
		
		/// Registers service in SCM database
		void serviceInstall(string _path = null)
		{
			wchar[MAX_PATH] path;
			wchar* pszPath;
			if (!_path) {
				if(!GetModuleFileNameW(null, path.ptr, MAX_PATH))
					throw new DaemonException("Cannot install service! " ~ getLastErrorDescr); 
				pszPath = path.ptr;
			}
			else {
				import std.utf : toUTF16z;
				pszPath = cast(wchar*)_path.toUTF16z;
			}
			auto manager = getSCManager();
			scope(exit) CloseServiceHandle(manager);
			
			auto servname = cast(LPWSTR)DaemonInfo.daemonName.toUTF16z;
			auto dispname = cast(LPWSTR)DaemonInfo.lang.serviceName.toUTF16z;
			import std.string : toStringz;
			auto desc = cast(LPWSTR)DaemonInfo.lang.serviceDescription.toUTF16z;
			auto service = CreateServiceW(
				manager,
				servname,
				dispname,
				SERVICE_ALL_ACCESS,
				SERVICE_WIN32_OWN_PROCESS,
				SERVICE_AUTO_START,
				SERVICE_ERROR_NORMAL,
				pszPath,
				null,
				null,
				null,
				null,
				null);
			
			if(service is null)
				throw new DaemonException("Failed to create service! " ~ getLastErrorDescr);
			
			scope(exit) CloseServiceHandle(service);
			BOOL ret = ChangeServiceConfig2W(service, cast(DWORD)1, cast(void*)&desc);
			
			if(ret == 0)
				throw new DaemonException("Failed to generate service description! " ~ getLastErrorDescr);
			
			SERVICE_FAILURE_ACTIONS servFailActions;
			SC_ACTION[2] failActions;
			
			failActions[0].Type = SC_ACTION_TYPE.SC_ACTION_RESTART; //Failure action: Restart Service
			failActions[0].Delay = 500; //number of ms to wait
			failActions[1].Type = SC_ACTION_TYPE.SC_ACTION_RESTART; //Failure action: Restart Service
			failActions[1].Delay = 500; //number of ms to wait
			
			servFailActions.dwResetPeriod = 86400; // Reset Failures Counter, in Seconds = 1day
			servFailActions.lpCommand = null; //Command to perform due to service failure, not used
			servFailActions.lpRebootMsg = null; //Message during rebooting computer due to service failure, not used
			servFailActions.cActions = 1; // Number of failure action to manage
			servFailActions.lpsaActions = failActions.ptr;
			
			ret = ChangeServiceConfig2W(service, cast(DWORD)2, cast(void*)&servFailActions); //Apply above settings
			if(ret == 0)
				throw new DaemonException("Failed to setup service autorecovery! " ~ getLastErrorDescr);
			
			BOOL readStoppedErrorCodes = 1;
			ret = ChangeServiceConfig2W(service, cast(DWORD)4, cast(void*)&readStoppedErrorCodes); //Apply above settings
			if(ret == 0)
				throw new DaemonException("Failed to setup service autorecovery bool flag! " ~ getLastErrorDescr);
			
			if(!StartServiceW(service, 0, null))
				throw new DaemonException(text("Failed to start service! ", getLastErrorDescr));
			
			SERVICE_STATUS status;
			while (status.dwCurrentState != SERVICE_RUNNING)
			{
				Thread.sleep(500.dur!"msecs");
				
				if(!QueryServiceStatus(service, &status))
					throw new DaemonException(text("Failed to query service! ", getLastErrorDescr));
				
			}
		}
		
		/// Removing service from SC manager
		void serviceRemove()
		{
			auto manager = getSCManager();
			scope(exit) CloseServiceHandle(manager);
			
			auto service = getService(manager, SERVICE_STOP | DELETE);
			scope(exit) CloseServiceHandle(service);
			
			DeleteService(service);
		}
		
		/// Tries to start service and checks the running state
		void serviceStart()
		{
			auto manager = getSCManager();
			scope(exit) CloseServiceHandle(manager);
			
			auto service = getService(manager, SERVICE_START);
			scope(exit) CloseServiceHandle(service);
			
			if(!StartServiceW(service, 0, null))
				throw new DaemonException(text("Failed to start service! ", getLastErrorDescr));
			
			
			auto maybeStatus = queryServiceStatus();
			if(maybeStatus.isNull)
			{
				throw new DaemonException("Failed to start service! There is no service registered!");
			}
			else
			{                
				auto status = maybeStatus.get;
				auto stamp = Clock.currTime(UTC());
				while(status.dwCurrentState != SERVICE_RUNNING)
				{
					if(stamp + 30.seconds < Clock.currTime(UTC())) 
						throw new DaemonException("Cannot start service! Timeout");
					if(status.dwWin32ExitCode != 0)
						throw new DaemonException(text("Failed to start service! Service error code: ", status.dwWin32ExitCode));
					if(status.dwCurrentState == SERVICE_STOPPED)
						throw new DaemonException("Failed to start service! The service remains in stop state!");
					
					auto maybeStatus2 = queryServiceStatus();
					if(maybeStatus2.isNull)
					{
						throw new DaemonException("Failed to start service! There is no service registered!");
					}
					else
					{
						status = maybeStatus2.get;
					}
				}
			}
		}
		
		/**
        *    Checks if the service is exist and returns its status.
        *
        *    If no service is installed, will return Nothing.
        */
		Nullable!SERVICE_STATUS queryServiceStatus()
		{
			auto manager = getSCManager();
			scope(exit) CloseServiceHandle(manager);
			
			SC_HANDLE service;
			try
			{
				service = getService(manager, SERVICE_QUERY_STATUS);
			} catch(Exception e)
			{
				Nullable!SERVICE_STATUS ret;
				return ret;
			}
			scope(exit) CloseServiceHandle(service);
			
			SERVICE_STATUS status;
			if(!QueryServiceStatus(service, &status))
				throw new DaemonException(text("Failed to query service! ", getLastErrorDescr));
			
			return Nullable!SERVICE_STATUS(status);
		}
		
		/// Sets current service status and reports it to the SCM
		void reportServiceStatus(DWORD currentState, DWORD exitCode, Duration waitHint)
		{
			static DWORD checkPoint = 1;
			
			serviceStatus.dwCurrentState = currentState;
			serviceStatus.dwWin32ExitCode = exitCode;
			serviceStatus.dwWaitHint = cast(DWORD)waitHint.total!"msecs";
			
			if(currentState == SERVICE_START_PENDING)
			{
				serviceStatus.dwControlsAccepted = 0;
			}
			else
			{
				serviceStatus.dwControlsAccepted = daemon.makeUsingFlag;
			}
			
			SetServiceStatus(serviceStatusHandle, &serviceStatus);
		}
		
		/// Reads last error id and formats it into a man-readable message
		string getLastErrorDescr()
		{
			char* buffer;
			auto error = GetLastError();
			
			FormatMessageA(
				FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_IGNORE_INSERTS, null, error, MAKELANGID(LANG_ENGLISH, SUBLANG_DEFAULT), cast(LPSTR)&buffer, 0, null);
			scope(exit) LocalFree(cast(void*)buffer);
			
			return buffer.fromStringz[0 .. $-1].idup;
		}
	} // private
}
private
{
	/// Handles utilities for signal mapping from local representation to GNU/Linux one
	template readDaemonInfo(alias DaemonInfo)
		if(isDaemon!DaemonInfo || isDaemonClient!DaemonInfo)
	{
		template extractCustomSignals(T...)
		{
			static if(T.length < 2) alias extractCustomSignals = T[0];
			else static if(isComposition!(T[1])) alias extractCustomSignals = StrictExpressionList!(T[0].expand, staticFilter!(isCustomSignal, T[1].signals));
			else static if(isCustomSignal(T[1])) alias extractCustomSignals = StrictExpressionList!(T[0].expand, T[1]);
			else alias extractCustomSignals = T[0];
		}
		
		template extractNativeSignals(T...)
		{
			static if(T.length < 2) alias extractNativeSignals = T[0];
			else static if(isComposition!(T[1])) alias extractNativeSignals = StrictExpressionList!(T[0].expand, staticFilter!(isNativeSignal, T[1].signals));
			else static if(isNativeSignal(T[1])) alias extractNativeSignals = StrictExpressionList!(T[0].expand, T[1]);
			else alias extractNativeSignals = T[0];
		}
		
		static if(isDaemon!DaemonInfo)
		{
			alias customSignals = staticFold!(extractCustomSignals, StrictExpressionList!(), DaemonInfo.signalMap.keys).expand; //pragma(msg, [customSignals]);
			alias nativeSignals = staticFold!(extractNativeSignals, StrictExpressionList!(), DaemonInfo.signalMap.keys).expand; //pragma(msg, [nativeSignals]);
		} else
		{ 
			alias customSignals = staticFold!(extractCustomSignals, StrictExpressionList!(), DaemonInfo.signals).expand; //pragma(msg, [customSignals]);
			alias nativeSignals = staticFold!(extractNativeSignals, StrictExpressionList!(), DaemonInfo.signals).expand; //pragma(msg, [nativeSignals]);
		}
		
		DWORD mapSignal(Signal sig)
		{
			switch(sig)
			{
				case(Signal.Stop):           return SERVICE_CONTROL_STOP;
				case(Signal.Continue):       return SERVICE_CONTROL_CONTINUE;
				case(Signal.Pause):          return SERVICE_CONTROL_PAUSE;
				case(Signal.Shutdown):       return SERVICE_CONTROL_SHUTDOWN;
				case(Signal.Interrogate):    return SERVICE_CONTROL_INTERROGATE;
				case(Signal.NetBindAdd):     return SERVICE_CONTROL_NETBINDADD;
				case(Signal.NetBindDisable): return SERVICE_CONTROL_NETBINDDISABLE;
				case(Signal.NetBindEnable):  return SERVICE_CONTROL_NETBINDENABLE;
				case(Signal.NetBindRemove):  return SERVICE_CONTROL_NETBINDREMOVE;
				case(Signal.ParamChange):    return SERVICE_CONTROL_PARAMCHANGE;
				default: return mapCustomSignal(sig);
			}
		}
		
		DWORD mapCustomSignal(Signal sig)
		{
			assert(!isNativeSignal(sig));
			
			DWORD counter = 0;
			foreach(key; customSignals)
			{
				if(key == sig) return 128 + counter;
				counter++;
			}
			
			assert(false, "Signal isn't in custom list! Impossible state!");
		}
		
		DWORD makeUsingFlag()
		{
			DWORD accum = 0;
			
			foreach(signal; nativeSignals)
			{
				static if(signal == Signal.Stop)            accum |= SERVICE_ACCEPT_STOP;
				static if(signal == Signal.Continue)        accum |= SERVICE_ACCEPT_PAUSE_CONTINUE;
				static if(signal == Signal.Pause)           accum |= SERVICE_ACCEPT_PAUSE_CONTINUE;
				static if(signal == Signal.Shutdown)        accum |= SERVICE_ACCEPT_SHUTDOWN;
				static if(signal == Signal.Interrogate)     accum |= 0;
				static if(signal == Signal.NetBindAdd)      accum |= SERVICE_ACCEPT_NETBINDCHANGE;
				static if(signal == Signal.NetBindDisable)  accum |= SERVICE_ACCEPT_NETBINDCHANGE;
				static if(signal == Signal.NetBindEnable)   accum |= SERVICE_ACCEPT_NETBINDCHANGE;
				static if(signal == Signal.NetBindRemove)   accum |= SERVICE_ACCEPT_NETBINDCHANGE;
				static if(signal == Signal.ParamChange)     accum |= SERVICE_ACCEPT_PARAMCHANGE;
			}
			
			return accum;
		}
		
		DWORD getControlAccessFlag(Signal sig)
		{
			switch(sig)
			{
				case(Signal.Stop):           return SERVICE_STOP;
				case(Signal.Continue):       return SERVICE_PAUSE_CONTINUE;
				case(Signal.Pause):          return SERVICE_PAUSE_CONTINUE;
				case(Signal.Shutdown):       throw new Error("Cannot send the shutdown signal!");
				case(Signal.Interrogate):    return SERVICE_INTERROGATE ;
				case(Signal.NetBindAdd):     return SERVICE_PAUSE_CONTINUE;
				case(Signal.NetBindDisable): return SERVICE_PAUSE_CONTINUE;
				case(Signal.NetBindEnable):  return SERVICE_PAUSE_CONTINUE;
				case(Signal.NetBindRemove):  return SERVICE_PAUSE_CONTINUE;
				case(Signal.ParamChange):    return SERVICE_PAUSE_CONTINUE;
				default: return SERVICE_USER_DEFINED_CONTROL;
			}
		}
	}
}
private nothrow
{
	extern (C) void  gc_init_tls();
	extern (C) void  gc_term_tls();
	extern (C) void  rt_moduleTlsCtor();
	extern (C) void  rt_moduleTlsDtor();
}
// winapi defines
private extern(System) 
{
	struct SERVICE_TABLE_ENTRY 
	{
		LPWSTR                  lpServiceName;
		LPSERVICE_MAIN_FUNCTION lpServiceProc;
	}
	alias LPSERVICE_TABLE_ENTRY = SERVICE_TABLE_ENTRY*;
	
	alias extern(System) void function(DWORD dwArgc, LPWSTR* lpszArgv) LPSERVICE_MAIN_FUNCTION;
	
	BOOL StartServiceCtrlDispatcherW(const SERVICE_TABLE_ENTRY* lpServiceTable);
	
	struct SERVICE_STATUS
	{
		DWORD dwServiceType;
		DWORD dwCurrentState;
		DWORD dwControlsAccepted;
		DWORD dwWin32ExitCode;
		DWORD dwServiceSpecificExitCode;
		DWORD dwCheckPoint;
		DWORD dwWaitHint;
	}
	alias LPSERVICE_STATUS = SERVICE_STATUS*;
	
	alias SERVICE_STATUS_HANDLE = HANDLE;
	alias SC_HANDLE = HANDLE;
	
	// dwServiceType
	enum SERVICE_FILE_SYSTEM_DRIVER = 0x00000002;
	enum SERVICE_KERNEL_DRIVER = 0x00000001;
	enum SERVICE_WIN32_OWN_PROCESS = 0x00000010;
	enum SERVICE_WIN32_SHARE_PROCESS = 0x00000020;
	enum SERVICE_INTERACTIVE_PROCESS = 0x00000100;
	
	// dwCurrentState
	enum SERVICE_CONTINUE_PENDING = 0x00000005;
	enum SERVICE_PAUSE_PENDING = 0x00000006;
	enum SERVICE_PAUSED = 0x00000007;
	enum SERVICE_RUNNING = 0x00000004;
	enum SERVICE_START_PENDING = 0x00000002;
	enum SERVICE_STOP_PENDING = 0x00000003;
	enum SERVICE_STOPPED = 0x00000001;
	
	// dwControlsAccepted
	enum SERVICE_ACCEPT_NETBINDCHANGE = 0x00000010;
	enum SERVICE_ACCEPT_PARAMCHANGE = 0x00000008;
	enum SERVICE_ACCEPT_PAUSE_CONTINUE = 0x00000002;
	enum SERVICE_ACCEPT_PRESHUTDOWN = 0x00000100;
	enum SERVICE_ACCEPT_SHUTDOWN = 0x00000004;
	enum SERVICE_ACCEPT_STOP = 0x00000001;
	
	enum NO_ERROR = 0;
	
	alias extern(System) void function(DWORD fdwControl) LPHANDLER_FUNCTION;
	SERVICE_STATUS_HANDLE RegisterServiceCtrlHandlerW(LPWSTR lpServiceName, LPHANDLER_FUNCTION lpHandlerProc);
	
	SC_HANDLE OpenSCManagerW(LPWSTR lpMachineName, LPWSTR lpDatabaseName, DWORD dwDesiredAccess);
	
	// dwDesiredAccess
	enum SC_MANAGER_ALL_ACCESS = 0xF003F;
	enum SC_MANAGER_CREATE_SERVICE = 0x0002;
	enum SC_MANAGER_CONNECT = 0x0001;
	enum SC_MANAGER_ENUMERATE_SERVICE = 0x0004;
	enum SC_MANAGER_LOCK = 0x0008;
	enum SC_MANAGER_MODIFY_BOOT_CONFIG = 0x0020;
	enum SC_MANAGER_QUERY_LOCK_STATUS = 0x0010;
	
	enum SC_ACTION_TYPE {
		SC_ACTION_NONE = 0,
		SC_ACTION_REBOOT = 2,
		SC_ACTION_RESTART = 1,
		SC_ACTION_RUN_COMMAND = 3
	}
	
	struct SC_ACTION {
		SC_ACTION_TYPE Type;
		DWORD          Delay;
	}
	
	// hService is the service handle obtained with OpenService
	
	struct SERVICE_FAILURE_ACTIONS {
		DWORD     dwResetPeriod;
		LPTSTR    lpRebootMsg;
		LPTSTR    lpCommand;
		DWORD     cActions;
		SC_ACTION *lpsaActions;
	}
	
	BOOL ChangeServiceConfig2W(SC_HANDLE, DWORD, LPVOID);
	
	SC_HANDLE CreateServiceW(
		SC_HANDLE hSCManager,
		LPWSTR lpServiceName,
		LPWSTR lpDisplayName,
		DWORD dwDesiredAccess,
		DWORD dwServiceType,
		DWORD dwStartType,
		DWORD dwErrorControl,
		LPWSTR lpBinaryPathName,
		LPWSTR lpLoadOrderGroup,
		LPDWORD lpdwTagId,
		LPWSTR lpDependencies,
		LPWSTR lpServiceStartName,
		LPWSTR lpPassword
		);
	
	// dwStartType
	enum SERVICE_AUTO_START = 0x00000002;
	enum SERVICE_BOOT_START = 0x00000000;
	enum SERVICE_DEMAND_START = 0x00000003;
	enum SERVICE_DISABLED = 0x00000004;
	enum SERVICE_SYSTEM_START = 0x00000001;
	
	// dwDesiredAccess CreateService
	enum SERVICE_ALL_ACCESS = 0xF01FF;
	enum SERVICE_CHANGE_CONFIG = 0x0002;
	enum SERVICE_ENUMERATE_DEPENDENTS = 0x0008;
	enum SERVICE_INTERROGATE = 0x0080;
	enum SERVICE_PAUSE_CONTINUE = 0x0040;
	enum SERVICE_QUERY_CONFIG = 0x0001;
	enum SERVICE_QUERY_STATUS = 0x0004;
	enum SERVICE_START = 0x0010;
	enum SERVICE_STOP = 0x0020;
	enum SERVICE_USER_DEFINED_CONTROL = 0x0100;
	
	// dwErrorControl 
	enum SERVICE_ERROR_CRITICAL = 0x00000003;
	enum SERVICE_ERROR_IGNORE = 0x00000000;
	enum SERVICE_ERROR_NORMAL = 0x00000001;
	enum SERVICE_ERROR_SEVERE = 0x00000002;
	
	bool CloseServiceHandle(SC_HANDLE hSCOjbect);
	
	SC_HANDLE OpenServiceW(
		SC_HANDLE hSCManager,
		LPWSTR lpServiceName,
		DWORD dwDesiredAccess
		);
	
	BOOL DeleteService(
		SC_HANDLE hService
		);
	
	BOOL StartServiceW(
		SC_HANDLE hService,
		DWORD dwNumServiceArgs,
		LPWSTR *lpServiceArgVectors
		);
	
	BOOL QueryServiceStatus(
		SC_HANDLE hService,
		LPSERVICE_STATUS lpServiceStatus
		);
	
	BOOL SetServiceStatus(
		SERVICE_STATUS_HANDLE hServiceStatus,
		LPSERVICE_STATUS lpServiceStatus
		);
	
	BOOL ControlService(
		SC_HANDLE hService,
		DWORD dwControl,
		LPSERVICE_STATUS lpServiceStatus
		);
	
	enum SERVICE_CONTROL_CONTINUE = 0x00000003;
	enum SERVICE_CONTROL_INTERROGATE = 0x00000004;
	enum SERVICE_CONTROL_NETBINDADD = 0x00000007;
	enum SERVICE_CONTROL_NETBINDDISABLE = 0x0000000A;
	enum SERVICE_CONTROL_NETBINDENABLE = 0x00000009;
	enum SERVICE_CONTROL_NETBINDREMOVE = 0x00000008;
	enum SERVICE_CONTROL_PARAMCHANGE = 0x00000006;
	enum SERVICE_CONTROL_PAUSE = 0x00000002;
	enum SERVICE_CONTROL_SHUTDOWN = 0x00000005;
	enum SERVICE_CONTROL_STOP = 0x00000001;
	
	enum ERROR_FAILED_SERVICE_CONTROLLER_CONNECT = 1063;
}