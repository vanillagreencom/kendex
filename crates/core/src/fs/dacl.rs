//! Creating a file only the account kendex runs as may open, on Windows.
//!
//! A new file takes its folder's access-control list unless the create
//! hands `CreateFileW` a security descriptor of its own, so the list is
//! built here and passed at creation: an owner-only list applied a moment
//! later would leave a window in which anyone the folder admits can open
//! the file, and a handle opened in that window keeps reading after the
//! list narrows. Win32 has no safe binding for any of this, which is why
//! the functions here alone in the workspace carry `unsafe`; every call
//! site states the contract it upholds.

use std::fs::File;
use std::io;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::ptr;

use windows_sys::Win32::Foundation::{GENERIC_WRITE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACL, ACL_REVISION, AddAccessAllowedAce, GetLengthSid, GetTokenInformation,
    InitializeAcl, InitializeSecurityDescriptor, PSID, SE_DACL_PROTECTED, SECURITY_ATTRIBUTES,
    SECURITY_DESCRIPTOR, SetSecurityDescriptorControl, SetSecurityDescriptorDacl, TOKEN_QUERY,
    TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{CREATE_NEW, CreateFileW, FILE_ALL_ACCESS};
use windows_sys::Win32::System::SystemServices::SECURITY_DESCRIPTOR_REVISION;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

/// Create `path`, refusing if it exists, with an access-control list that
/// names the current account and nobody else. The list is marked protected
/// so the folder's inheritable entries are not merged in behind it. A step
/// that fails refuses the create, naming the step: a file with the folder's
/// list is the outcome this exists to prevent, not a fallback.
#[allow(
    unsafe_code,
    reason = "Win32 has no safe binding; each site states its contract"
)]
pub(super) fn create_owner_only(path: &Path) -> io::Result<File> {
    let user = current_user()?;
    let sid = user.sid();

    // The sizing rule `AddAccessAllowedAce` documents: the header, one
    // allowed entry whose trailing `SidStart` word is replaced by the SID.
    // SAFETY: `sid` points into `user`, which outlives this call.
    let sid_len = unsafe { GetLengthSid(sid) } as usize;
    let acl_len = size_of::<ACL>() + size_of::<ACCESS_ALLOWED_ACE>() - size_of::<u32>() + sid_len;
    // `ACL` and the entries behind it are 4-byte aligned; a `u32` buffer
    // guarantees that where a `u8` one would not.
    let mut acl = vec![0u32; acl_len.div_ceil(size_of::<u32>())];
    let acl_ptr: *mut ACL = acl.as_mut_ptr().cast();
    // SAFETY: `acl` holds `acl_len` writable bytes for the length of this
    // function, aligned for `ACL`, and `sid` is a valid SID (above).
    if unsafe { InitializeAcl(acl_ptr, acl_len as u32, ACL_REVISION) } == 0 {
        return Err(failed("InitializeAcl"));
    }
    // SAFETY: as above; the ACL was sized for exactly this one entry.
    if unsafe { AddAccessAllowedAce(acl_ptr, ACL_REVISION, FILE_ALL_ACCESS, sid) } == 0 {
        return Err(failed("AddAccessAllowedAce"));
    }

    let mut descriptor = SECURITY_DESCRIPTOR::default();
    let descriptor_ptr = ptr::from_mut(&mut descriptor).cast();
    // SAFETY: `descriptor` is a live, writable, correctly typed
    // `SECURITY_DESCRIPTOR` for every call below, and `acl` outlives it.
    // The descriptor holds a pointer into `acl`, never a copy, so `acl` is
    // kept alive through the `CreateFileW` call at the end.
    unsafe {
        if InitializeSecurityDescriptor(descriptor_ptr, SECURITY_DESCRIPTOR_REVISION) == 0 {
            return Err(failed("InitializeSecurityDescriptor"));
        }
        if SetSecurityDescriptorDacl(descriptor_ptr, 1, acl_ptr, 0) == 0 {
            return Err(failed("SetSecurityDescriptorDacl"));
        }
        if SetSecurityDescriptorControl(descriptor_ptr, SE_DACL_PROTECTED, SE_DACL_PROTECTED) == 0 {
            return Err(failed("SetSecurityDescriptorControl"));
        }
    }

    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor_ptr,
        bInheritHandle: 0,
    };
    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: `wide` is NUL-terminated and lives across the call, and
    // `attributes` points at a descriptor and ACL that are both still
    // alive. A share mode of zero refuses every other open while the
    // handle is held, so nothing reads the file before the bytes land.
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            GENERIC_WRITE,
            0,
            &attributes,
            CREATE_NEW,
            0,
            ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `handle` is a valid file handle this function owns, opened
    // just above and given to nothing else.
    Ok(unsafe { File::from_raw_handle(handle) })
}

/// The account this process runs as: the `TOKEN_USER` of its own token,
/// kept in the buffer the system filled so the SID pointer inside it
/// stays valid.
pub(super) struct CurrentUser(Vec<u64>);

impl CurrentUser {
    /// The account's SID, pointing into this value.
    #[allow(
        unsafe_code,
        reason = "Win32 has no safe binding; each site states its contract"
    )]
    pub(super) fn sid(&self) -> PSID {
        // SAFETY: `GetTokenInformation` filled the buffer with a
        // `TOKEN_USER` at offset zero; a `u64` buffer is aligned for it.
        unsafe { (*self.0.as_ptr().cast::<TOKEN_USER>()).User.Sid }
    }
}

/// Read the current process token's user.
#[allow(
    unsafe_code,
    reason = "Win32 has no safe binding; each site states its contract"
)]
pub(super) fn current_user() -> io::Result<CurrentUser> {
    let mut raw = ptr::null_mut();
    // SAFETY: the pseudo-handle from `GetCurrentProcess` needs no closing,
    // and `raw` is a writable out-parameter.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut raw) } == 0 {
        return Err(failed("OpenProcessToken"));
    }
    // SAFETY: `raw` is the token handle opened above and owned by nothing
    // else; `OwnedHandle` closes it on drop.
    let token = unsafe { OwnedHandle::from_raw_handle(raw) };
    let mut len = 0u32;
    // SAFETY: a null buffer of length zero is the documented sizing call;
    // it fails with the needed length in `len`.
    unsafe {
        GetTokenInformation(
            token.as_raw_handle(),
            TokenUser,
            ptr::null_mut(),
            0,
            &mut len,
        );
    }
    if len == 0 {
        return Err(failed("GetTokenInformation"));
    }
    let mut buffer = vec![0u64; (len as usize).div_ceil(size_of::<u64>())];
    // SAFETY: `buffer` holds at least `len` writable bytes, aligned for
    // `TOKEN_USER`, and `token` is open for query.
    let filled = unsafe {
        GetTokenInformation(
            token.as_raw_handle(),
            TokenUser,
            buffer.as_mut_ptr().cast(),
            len,
            &mut len,
        )
    };
    if filled == 0 {
        return Err(failed("GetTokenInformation"));
    }
    Ok(CurrentUser(buffer))
}

/// The refusal for a Win32 step that reported failure: the step by name,
/// with the system's own account of why, so the person saving a
/// credential reads which part of giving the file an owner-only list
/// could not be done rather than a bare create error.
fn failed(step: &str) -> io::Error {
    let cause = io::Error::last_os_error();
    io::Error::new(
        cause.kind(),
        format!("could not give the new file an owner-only access-control list ({step}: {cause})"),
    )
}
