//! Creating a file only the account kendex runs as may open, on Windows.
//!
//! A new file takes its folder's access-control list unless the create
//! hands `CreateFileW` a security descriptor of its own, so the list is
//! built here and passed at creation: an owner-only list applied a moment
//! later would leave a window in which anyone the folder admits can open
//! the file, and a handle opened in that window keeps reading after the
//! list narrows. Win32 has no safe binding for any of this; every call
//! site states the contract it upholds.

use std::fs::File;
use std::io;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::ptr;

use windows_sys::Win32::Foundation::{
    ERROR_SUCCESS, GENERIC_WRITE, INVALID_HANDLE_VALUE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{GetSecurityInfo, SE_FILE_OBJECT};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACL, ACL_REVISION, ACL_SIZE_INFORMATION, AclSizeInformation,
    AddAccessAllowedAce, DACL_SECURITY_INFORMATION, EqualSid, GetAce, GetAclInformation,
    GetLengthSid, GetTokenInformation, INHERITED_ACE, InitializeAcl, InitializeSecurityDescriptor,
    PSID, SE_DACL_PROTECTED, SECURITY_ATTRIBUTES, SECURITY_DESCRIPTOR,
    SetSecurityDescriptorControl, SetSecurityDescriptorDacl, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    CREATE_NEW, CreateFileW, DELETE, FILE_ALL_ACCESS, FILE_DISPOSITION_FLAG_DO_NOT_DELETE,
    FILE_DISPOSITION_FLAG_ON_CLOSE, FILE_DISPOSITION_INFO_EX, FILE_FLAG_DELETE_ON_CLOSE,
    FileDispositionInfoEx, SetFileInformationByHandle,
};
use windows_sys::Win32::System::SystemServices::{
    ACCESS_ALLOWED_ACE_TYPE, SECURITY_DESCRIPTOR_REVISION,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

/// Create `path`, refusing if it exists, with an access-control list that
/// names the current account and nobody else. The list is read back
/// through the handle before the file is handed out: a volume that keeps
/// no lists, FAT among them, accepts the descriptor and creates the file
/// open to everyone. Until that read-back confirms the list the file is
/// pending deletion at close, so every way out of here without a
/// confirmed list takes the empty file with it and no retry can meet a
/// leftover the folder's list governs. A step that fails refuses the
/// create, naming the step: a file with the folder's list is the outcome
/// this exists to prevent, not a fallback.
pub(super) fn create_owner_only(path: &Path) -> io::Result<File> {
    let user = current_user()?;
    let file = create_pending(path, user.sid())?;
    applied(&file, user.sid())?;
    keep(&file)?;
    Ok(file)
}

/// `path` created with the owner-only list for `sid` in its security
/// descriptor, marked protected so the folder's inheritable entries are
/// not merged in behind it, and pending deletion when its handle closes
/// until [`keep`] says otherwise.
#[allow(
    unsafe_code,
    reason = "Win32 has no safe binding; each site states its contract"
)]
pub(super) fn create_pending(path: &Path, sid: PSID) -> io::Result<File> {
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
        return Err(failed("InitializeAcl", io::Error::last_os_error()));
    }
    // SAFETY: as above; the ACL was sized for exactly this one entry.
    if unsafe { AddAccessAllowedAce(acl_ptr, ACL_REVISION, FILE_ALL_ACCESS, sid) } == 0 {
        return Err(failed("AddAccessAllowedAce", io::Error::last_os_error()));
    }

    let mut descriptor = SECURITY_DESCRIPTOR::default();
    let descriptor_ptr = ptr::from_mut(&mut descriptor).cast();
    // SAFETY: `descriptor` is a live, writable, correctly typed
    // `SECURITY_DESCRIPTOR` for every call below, and `acl` outlives it.
    // The descriptor holds a pointer into `acl`, never a copy, so `acl` is
    // kept alive through the `CreateFileW` call at the end.
    unsafe {
        if InitializeSecurityDescriptor(descriptor_ptr, SECURITY_DESCRIPTOR_REVISION) == 0 {
            return Err(failed(
                "InitializeSecurityDescriptor",
                io::Error::last_os_error(),
            ));
        }
        if SetSecurityDescriptorDacl(descriptor_ptr, 1, acl_ptr, 0) == 0 {
            return Err(failed(
                "SetSecurityDescriptorDacl",
                io::Error::last_os_error(),
            ));
        }
        if SetSecurityDescriptorControl(descriptor_ptr, SE_DACL_PROTECTED, SE_DACL_PROTECTED) == 0 {
            return Err(failed(
                "SetSecurityDescriptorControl",
                io::Error::last_os_error(),
            ));
        }
    }

    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor_ptr,
        bInheritHandle: 0,
    };
    // `std` is not between this path and Win32 to lift the legacy length
    // limit, so the spelling that does is taken here.
    let wide: Vec<u16> = crate::paths::verbatim(path)?
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
            GENERIC_WRITE | DELETE,
            0,
            &attributes,
            CREATE_NEW,
            FILE_FLAG_DELETE_ON_CLOSE,
            ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(failed("CreateFileW", io::Error::last_os_error()));
    }
    // SAFETY: `handle` is a valid file handle this function owns, opened
    // just above and given to nothing else.
    Ok(unsafe { File::from_raw_handle(handle) })
}

/// Clear the deletion at close a pending file was created with. A clear
/// that fails is a refusal, and the file goes with the handle as it would
/// have anyway.
#[allow(
    unsafe_code,
    reason = "Win32 has no safe binding; each site states its contract"
)]
pub(super) fn keep(file: &File) -> io::Result<()> {
    let disposition = FILE_DISPOSITION_INFO_EX {
        Flags: FILE_DISPOSITION_FLAG_DO_NOT_DELETE | FILE_DISPOSITION_FLAG_ON_CLOSE,
    };
    // SAFETY: `file` holds an open handle with `DELETE` access, and
    // `disposition` is a live `FILE_DISPOSITION_INFO_EX` of the length
    // passed, the shape `FileDispositionInfoEx` reads.
    let cleared = unsafe {
        SetFileInformationByHandle(
            file.as_raw_handle(),
            FileDispositionInfoEx,
            ptr::from_ref(&disposition).cast(),
            size_of::<FILE_DISPOSITION_INFO_EX>() as u32,
        )
    };
    match cleared {
        0 => Err(failed(
            "SetFileInformationByHandle",
            io::Error::last_os_error(),
        )),
        _ => Ok(()),
    }
}

/// Whether the list `file` carries is the one this module writes, read
/// back through its handle: one entry, this account, full access, nothing
/// handed down. The outcome is tested rather than a volume capability
/// flag, so a volume that reports lists and keeps a different one is
/// refused too.
#[allow(
    unsafe_code,
    reason = "Win32 has no safe binding; each site states its contract"
)]
pub(super) fn applied(file: &File, account: PSID) -> io::Result<()> {
    let mut dacl = ptr::null_mut();
    let mut descriptor = ptr::null_mut();
    // SAFETY: `file` holds an open handle; the out-parameters are
    // writable; the descriptor the system allocates is freed below after
    // the last read through `dacl`, which points into it.
    let read = unsafe {
        GetSecurityInfo(
            file.as_raw_handle(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            ptr::null_mut(),
            ptr::null_mut(),
            &mut dacl,
            ptr::null_mut(),
            &mut descriptor,
        )
    };
    if read != ERROR_SUCCESS {
        // The status is the return value; the thread's last error is
        // whatever an earlier call left there.
        return Err(failed(
            "GetSecurityInfo",
            io::Error::from_raw_os_error(read as i32),
        ));
    }
    // SAFETY: `dacl` is the list `GetSecurityInfo` reported, null where
    // the file has none, alive until the free below; `account` is valid.
    let found = unsafe { entries(dacl, account) };
    // SAFETY: `descriptor` came from `GetSecurityInfo`, which documents
    // `LocalFree` as its release, and nothing reads through it after this.
    unsafe { LocalFree(descriptor) };
    match found? == [OWNER_ONLY] {
        true => Ok(()),
        false => Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "could not give the new file an owner-only access-control list (the volume did not keep it)",
        )),
    }
}

/// One entry of an access-control list, as far as this module reads one.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Entry {
    pub(crate) allowed: bool,
    pub(crate) this_account: bool,
    pub(crate) mask: u32,
    pub(crate) inherited: bool,
}

/// The one entry `create_owner_only` writes.
pub(crate) const OWNER_ONLY: Entry = Entry {
    allowed: true,
    this_account: true,
    mask: FILE_ALL_ACCESS,
    inherited: false,
};

/// The entries of `dacl`, in order; a null list, which admits everyone,
/// has none. A list that cannot be read is a refusal naming the call,
/// never an empty answer a caller would take for a list.
///
/// # Safety
///
/// `dacl` is null or a valid access-control list alive for the call, and
/// `account` a valid SID.
#[allow(
    unsafe_code,
    reason = "Win32 has no safe binding; each site states its contract"
)]
pub(super) unsafe fn entries(dacl: *const ACL, account: PSID) -> io::Result<Vec<Entry>> {
    if dacl.is_null() {
        return Ok(Vec::new());
    }
    let mut size = ACL_SIZE_INFORMATION {
        AceCount: 0,
        AclBytesInUse: 0,
        AclBytesFree: 0,
    };
    // SAFETY: `dacl` is valid by the caller's contract and `size` a
    // writable `ACL_SIZE_INFORMATION` of the length passed.
    let sized = unsafe {
        GetAclInformation(
            dacl,
            ptr::from_mut(&mut size).cast(),
            size_of::<ACL_SIZE_INFORMATION>() as u32,
            AclSizeInformation,
        )
    };
    if sized == 0 {
        return Err(failed("GetAclInformation", io::Error::last_os_error()));
    }
    (0..size.AceCount)
        .map(|index| {
            let mut ace = ptr::null_mut();
            // SAFETY: `index` is below the count the list reported, so
            // `GetAce` yields a pointer to an entry inside `dacl`, alive by
            // the caller's contract. Every entry starts with an
            // `ACE_HEADER`, and an allowed entry is an `ACCESS_ALLOWED_ACE`
            // whose `SidStart` opens its SID.
            unsafe {
                if GetAce(dacl, index, &mut ace) == 0 {
                    return Err(failed("GetAce", io::Error::last_os_error()));
                }
                let ace = &*ace.cast::<ACCESS_ALLOWED_ACE>();
                let allowed = u32::from(ace.Header.AceType) == ACCESS_ALLOWED_ACE_TYPE;
                Ok(Entry {
                    allowed,
                    this_account: allowed
                        && EqualSid(ptr::from_ref(&ace.SidStart).cast_mut().cast(), account) != 0,
                    mask: ace.Mask,
                    inherited: u32::from(ace.Header.AceFlags) & INHERITED_ACE != 0,
                })
            }
        })
        .collect()
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
        return Err(failed("OpenProcessToken", io::Error::last_os_error()));
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
        return Err(failed("GetTokenInformation", io::Error::last_os_error()));
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
        return Err(failed("GetTokenInformation", io::Error::last_os_error()));
    }
    Ok(CurrentUser(buffer))
}

/// A Win32 step that reported failure, with the system's own account of
/// why, so the person saving a credential reads which part of giving the
/// file an owner-only list could not be done rather than a bare create
/// error. The cause is the caller's to supply, at the call, from wherever
/// that API reports it: the thread's last error for most, the return
/// value for the rest. Read in a helper instead, it would be whatever the
/// previous call left behind.
#[derive(Debug)]
pub(super) struct Failed {
    pub(super) step: &'static str,
    pub(super) cause: io::Error,
}

impl std::fmt::Display for Failed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "could not give the new file an owner-only access-control list ({}: {})",
            self.step, self.cause
        )
    }
}

impl std::error::Error for Failed {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.cause)
    }
}

/// The refusal for a failed step, keeping the cause's kind so a caller
/// matching on it, as `write_private` does for an existing file, still
/// can.
fn failed(step: &'static str, cause: io::Error) -> io::Error {
    io::Error::new(cause.kind(), Failed { step, cause })
}
