// helper_install — dev CLI: installs the privileged fan helper via SMJobBless.
// Lives inside MacTemp.app so its enclosing bundle's SMPrivilegedExecutables apply.
// Run once as root: osascript -e 'do shell script "/Applications/MacTemp.app/Contents/MacOS/helper_install" with administrator privileges'
import Foundation
import ServiceManagement

let label = "local.mactemp.helper"

var auth: AuthorizationRef?
let createStatus = AuthorizationCreate(nil, nil, [], &auth)
guard createStatus == errAuthorizationSuccess, let authorization = auth else {
    print("AuthorizationCreate failed: \(createStatus)")
    exit(1)
}

var item = AuthorizationItem(name: kSMRightBlessPrivilegedHelper, valueLength: 0, value: nil, flags: 0)
var itemSet = AuthorizationItemSet(count: 1, items: nil)
let copyStatus = withUnsafeMutablePointer(to: &item) { itemPtr in
    itemSet.items = itemPtr
    return withUnsafePointer(to: &itemSet) { setPtr in
        AuthorizationCopyRights(authorization, setPtr, nil, [.interactionAllowed, .extendRights], nil)
    }
}
if copyStatus != errAuthorizationSuccess {
    print("AuthorizationCopyRights failed: \(copyStatus)")
    AuthorizationFree(authorization, [])
    exit(copyStatus == errAuthorizationCanceled ? 128 : 1)
}

var errorRef: Unmanaged<CFError>?
let ok = SMJobBless(kSMDomainSystemLaunchd, label as CFString, authorization, &errorRef)
AuthorizationFree(authorization, [])

if ok {
    print("helper installed: \(label)")
    exit(0)
} else {
    let ns = errorRef?.takeRetainedValue() as NSError?
    print("SMJobBless failed: \(ns?.localizedDescription ?? "unknown") \(ns?.userInfo ?? [:])")
    exit(1)
}
