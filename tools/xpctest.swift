import Foundation

let sem = DispatchSemaphore(value: 0)
let conn = xpc_connection_create_mach_service("local.mactemp.helper", nil, 0)
xpc_connection_set_event_handler(conn) { event in
    let desc = xpc_copy_description(conn)
    print("event:", String(cString: xpc_copy_description(event)))
    print("conn:", desc)
    sem.signal()
}
xpc_connection_activate(conn)
let r = sem.wait(timeout: .now() + 10)
print("wait result:", r == .timedOut ? "TIMEOUT" : "got event")
print("final conn:", String(cString: xpc_copy_description(conn)))
