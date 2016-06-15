/**
	Thread based asynchronous file I/O fallback implementation

	Copyright: © 2012 RejectedSoftware e.K.
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.drivers.threadedfile;

import vibe.core.core : yield;
import vibe.core.log;
import vibe.core.driver;
import vibe.inet.url;
import vibe.utils.string;

import std.algorithm;
import std.conv;
import std.exception;
import std.string;
import core.stdc.errno;

version(Posix){
	import core.sys.posix.fcntl;
	import core.sys.posix.sys.stat;
	import core.sys.posix.unistd;
}
version(Windows){
	import std.utf : toUTF16z;
	import core.sys.windows.stat;

	private {
		extern(C){
			alias off_t = long;
			int open(in char* name, int mode, ...);
			int _wopen(in wchar* name, wchar mode, ...);
			int _wchmod(in wchar*, int);
			int chmod(in char* name, int mode);
			int close(int fd);
			int read(int fd, void *buffer, uint count);
			int write(int fd, in void *buffer, uint count);
			off_t lseek(int fd, off_t offset, int whence);
		}
		
		enum O_RDONLY = 0;
		enum O_WRONLY = 1;
		enum O_RDWR = 2;
		enum O_APPEND = 8;
		enum O_CREAT = 0x0100;
		enum O_TRUNC = 0x0200;
		enum O_BINARY = 0x8000;

		enum _S_IREAD = 0x0100;          /* read permission, owner */
		enum _S_IWRITE = 0x0080;          /* write permission, owner */
		alias stat_t = struct_stat;
	}
}
else
{
	enum O_BINARY = 0;
}

private {
	enum SEEK_SET = 0;
	enum SEEK_CUR = 1;
	enum SEEK_END = 2;
}
/******************************************************************************/
/* class Win32FileStream                                                      */
/******************************************************************************/
version(Windows)
final class Win32FileStream : FileStream {
	import vibe.internal.win32;
	alias UncaughtException = Throwable;
	private {
		Path m_path;
		HANDLE m_handle;
		FileMode m_mode;
		DriverCore m_driver;
		Task m_task;
		ulong m_size;
		ulong m_ptr = 0;
		DWORD m_bytesTransferred;
	}
	
	this(DriverCore driver, Path path, FileMode mode)
	{
		m_path = path;
		m_mode = mode;
		m_driver = driver;
		
		auto access = m_mode == FileMode.readWrite ? (GENERIC_WRITE | GENERIC_READ) :
		(m_mode == FileMode.createTrunc || m_mode == FileMode.append)? GENERIC_WRITE : GENERIC_READ;
		
		auto shareMode = m_mode == FileMode.read? FILE_SHARE_READ : 0;
		
		auto creation = m_mode == FileMode.createTrunc? CREATE_ALWAYS : m_mode == FileMode.append? OPEN_ALWAYS : OPEN_EXISTING;
		
		m_handle = CreateFileW(
			toUTF16z(m_path.toNativeString()),
			access,
			shareMode,
			null,
			creation,
			FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
			null);
		
		auto errorcode = GetLastError();
		enforce(m_handle != INVALID_HANDLE_VALUE, "Failed to open "~path.toNativeString()~": "~to!string(errorcode) ~ " Mode: " ~ mode.to!string);
		if(mode == FileMode.createTrunc && errorcode == ERROR_ALREADY_EXISTS)
		{
			// truncate file
			// TODO: seek to start pos?
			BOOL ret = SetEndOfFile(m_handle);
			errorcode = GetLastError();
			enforce(ret, "Failed to call SetFileEndPos for path "~path.toNativeString()~", Error: " ~ to!string(errorcode));
		}
		long size;
		auto succeeded = GetFileSizeEx(m_handle, &size);
		enforce(succeeded);
		m_size = size;
		if(mode == FileMode.append) {
			SetFilePointer(m_handle, 0, null, FILE_END);
			m_ptr = size;
		}
	}
	
	~this()
	{
		close();
	}
	
	void release()
	{
		assert(m_task == Task.getThis(), "Releasing FileStream that is not owned by the calling task.");
		m_task = Task();
	}
	
	void acquire()
	{
		assert(m_task == Task(), "Acquiring FileStream that is already owned.");
		m_task = Task.getThis();
	}
	
	bool amOwner()
	{
		return m_task == Task.getThis();
	}
	
	void close()
	{
		if(m_handle == INVALID_HANDLE_VALUE)
			return;
		CloseHandle(m_handle);
		m_handle = INVALID_HANDLE_VALUE;
	}
	
	ulong tell() { return m_ptr; }
	
	@property Path path() const { return m_path; }
	
	@property bool isOpen() const { return m_handle != INVALID_HANDLE_VALUE; }
	
	@property ulong size() const { return m_size; }
	
	@property bool readable()
	const {
		return m_mode != FileMode.append;
	}
	
	@property bool writable()
	const {
		return m_mode == FileMode.append || m_mode == FileMode.createTrunc || m_mode == FileMode.readWrite;
	}
	
	void seek(ulong offset)
	{
		m_ptr = offset;
	}
	
	
	@property bool empty() const { assert(this.readable); return m_ptr >= m_size; }
	@property ulong leastSize() const { assert(this.readable); return m_size - m_ptr; }
	@property bool dataAvailableForRead(){
		return leastSize() > 0;
	}
	
	const(ubyte)[] peek(){
		assert(false);
	}
	
	void read(ubyte[] dst)
	{
		assert(this.readable);
		acquire();
		scope(exit) release();
		
		while( dst.length > 0 ){
			enforce(dst.length <= leastSize);
			OVERLAPPED overlapped;
			overlapped.Internal = 0;
			overlapped.InternalHigh = 0;
			overlapped.Offset = cast(uint)(m_ptr & 0xFFFFFFFF);
			overlapped.OffsetHigh = cast(uint)(m_ptr >> 32);
			overlapped.hEvent = cast(HANDLE)cast(void*)this;
			m_bytesTransferred = 0;
			
			auto to_read = min(dst.length, DWORD.max);
			
			// request to write the data
			ReadFileEx(m_handle, cast(void*)dst, to_read, &overlapped, &onIOCompleted);
			
			// yield until the data is read
			while( !m_bytesTransferred ) m_driver.yieldForEvent();
			
			assert(m_bytesTransferred <= to_read, "More bytes read than requested!?");
			dst = dst[m_bytesTransferred .. $];
			m_ptr += m_bytesTransferred;
		}
	}
	
	void write(in ubyte[] bytes_)
	{
		logTrace("File write bytes offset: %d => %s", m_ptr, cast(string)bytes_);
		assert(this.writable);
		acquire();
		scope(exit) release();
		
		const(ubyte)[] bytes = bytes_;
		
		while( bytes.length > 0 ){
			OVERLAPPED overlapped;
			overlapped.Internal = 0;
			overlapped.InternalHigh = 0;
			overlapped.Offset = cast(uint)(m_ptr & 0xFFFFFFFF);
			overlapped.OffsetHigh = cast(uint)(m_ptr >> 32);
			overlapped.hEvent = cast(HANDLE)cast(void*)this;
			m_bytesTransferred = 0;
			
			auto to_write = min(bytes.length, DWORD.max);

			// request to write the data
			WriteFileEx(m_handle, cast(void*)bytes, to_write, &overlapped, &onIOCompleted);
			
			// yield until the data is written
			while( !m_bytesTransferred ) m_driver.yieldForEvent();
			
			assert(m_bytesTransferred <= to_write, "More bytes written than requested!?");
			bytes = bytes[m_bytesTransferred .. $];
			m_ptr += m_bytesTransferred;
		}
		if(m_ptr > m_size) m_size = m_ptr;
	}
	
	void flush(){}
	
	void finalize(){}
	
	void write(InputStream stream, ulong nbytes = 0)
	{
		writeDefault(stream, nbytes);
	}
	
	private static extern(System) nothrow
		void onIOCompleted(DWORD dwError, DWORD cbTransferred, OVERLAPPED* overlapped)
	{
		try {
			auto fileStream = cast(Win32FileStream)(overlapped.hEvent);
			fileStream.m_bytesTransferred = cbTransferred;
			if( fileStream.m_task ){
				Exception ex;
				if( dwError != 0 ) ex = new Exception("File I/O error: "~to!string(dwError));
				if( fileStream.m_task ) fileStream.m_driver.resumeTask(fileStream.m_task, ex);
			}
		} catch( UncaughtException e ){
			logWarn("Exception while handling file I/O: %s", e.msg);
		}
	}
}

final class ThreadedFileStream : FileStream {
	private {
		int m_fileDescriptor;
		Path m_path;
		ulong m_size;
		ulong m_ptr = 0;
		FileMode m_mode;
		bool m_ownFD = true;
	}
	
	this(Path path, FileMode mode)
	{
		auto pathstr = path.toNativeString();
		final switch(mode){
			case FileMode.read:
				version(Windows) {
					m_fileDescriptor = _wopen(pathstr.toUTF16z(), O_RDONLY|O_BINARY);
				} else
					m_fileDescriptor = open(pathstr.toStringz(), O_RDONLY|O_BINARY);
				break;
			case FileMode.readWrite:
				version(Windows) {
					m_fileDescriptor = _wopen(pathstr.toUTF16z(), O_RDWR|O_BINARY);
				} else
					m_fileDescriptor = open(pathstr.toStringz(), O_RDWR|O_BINARY);
				break;
			case FileMode.createTrunc:
				version(Windows) {
					m_fileDescriptor = _wopen(pathstr.toUTF16z(), O_RDWR|O_CREAT|O_TRUNC|O_BINARY, octal!644);
				} else
					m_fileDescriptor = open(pathstr.toStringz(), O_RDWR|O_CREAT|O_TRUNC|O_BINARY, octal!644);
				break;
			case FileMode.append:
				version(Windows) {
					m_fileDescriptor = _wopen(pathstr.toUTF16z(), O_WRONLY|O_CREAT|O_APPEND|O_BINARY, octal!644);
				} else
					m_fileDescriptor = open(pathstr.toStringz(), O_WRONLY|O_CREAT|O_APPEND|O_BINARY, octal!644);
				break;
		}
		if( m_fileDescriptor < 0 )
			//throw new Exception(format("Failed to open '%s' with %s: %d", pathstr, cast(int)mode, errno));
			throw new Exception("Failed to open file '"~pathstr~"'.");
		
		this(m_fileDescriptor, path, mode);
	}

	this(int fd, Path path, FileMode mode)
	{
		assert(fd >= 0);
		m_fileDescriptor = fd;
		m_path = path;
		m_mode = mode;

		version(linux){
			// stat_t seems to be defined wrong on linux/64
			m_size = .lseek(m_fileDescriptor, 0, SEEK_END);
		} else {
			stat_t st;
			fstat(m_fileDescriptor, &st);
			m_size = st.st_size;
			
			// (at least) on windows, the created file is write protected
			version(Windows){
				if( mode == FileMode.createTrunc ) 
				{
					_wchmod(path.toNativeString().toUTF16z(), S_IREAD|S_IWRITE);
				}
			}
		}
		lseek(m_fileDescriptor, 0, SEEK_SET);
		
		logDebug("opened file %s with %d bytes as %d", path.toNativeString(), m_size, m_fileDescriptor);
	}

	~this()
	{
		close();
	}
	
	@property int fd() { return m_fileDescriptor; }
	@property Path path() const { return m_path; }
	@property bool isOpen() const { return m_fileDescriptor >= 0; }
	@property ulong size() const { return m_size; }
	@property bool readable() const { return m_mode != FileMode.append; }
	@property bool writable() const { return m_mode != FileMode.read; }

	void takeOwnershipOfFD()
	{
		enforce(m_ownFD);
		m_ownFD = false;
	}

	void seek(ulong offset)
	{
		enforce(.lseek(m_fileDescriptor, offset, SEEK_SET) == offset, "Failed to seek in file.");
		m_ptr = offset;
	}

	ulong tell() { return m_ptr; }
	
	void close()
	{
		if( m_fileDescriptor != -1 && m_ownFD ){
			.close(m_fileDescriptor);
			m_fileDescriptor = -1;
		}
	}

	@property bool empty() const { assert(this.readable); return m_ptr >= m_size; }
	@property ulong leastSize() const { assert(this.readable); return m_size - m_ptr; }
	@property bool dataAvailableForRead() { return true; }

	const(ubyte)[] peek()
	{
		return null;
	}

	void read(ubyte[] dst)
	{
		assert(this.readable);
		while (dst.length > 0) {
			enforce(dst.length <= leastSize);
			auto sz = min(dst.length, 64*1024);
			enforce(.read(m_fileDescriptor, dst.ptr, cast(int)sz) == sz, "Failed to read data from disk.");
			dst = dst[sz .. $];
			m_ptr += sz;
		}
	}

	alias write = Stream.write;
	void write(in ubyte[] bytes_)
	{
		const(ubyte)[] bytes = bytes_;
		assert(this.writable);
		while (bytes.length > 0) {
			auto sz = min(bytes.length, 64*1024);
			auto ret = .write(m_fileDescriptor, bytes.ptr, cast(int)sz);
			enforce(ret == sz, "Failed to write data to disk."~to!string(sz)~" "~to!string(errno)~" "~to!string(ret)~" "~to!string(m_fileDescriptor));
			bytes = bytes[sz .. $];
			m_ptr += sz;
		}
	}

	void write(InputStream stream, ulong nbytes = 0)
	{
		writeDefault(stream, nbytes);
	}

	void flush()
	{
		assert(this.writable);
	}

	void finalize()
	{
		flush();
	}
}
