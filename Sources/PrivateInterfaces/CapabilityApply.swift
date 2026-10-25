package import Foundation

extension CapabilityEntry {
    private typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias Getter = @convention(c) (AnyObject, Selector) -> Bool

    /// Sets the switch on `object` and reads it back. The object must be an instance of the setter's class, and the contract
    /// must hold now (`status(in:)`); otherwise nothing is called. If the value read back is not the value set, the value the
    /// switch had is put back and the capability is reported unavailable.
    package func apply(_ value: Bool, to object: NSObject, in context: PrivateCapabilityContext) -> PrivateCapabilityStatus {
        let checked = status(in: context)
        guard checked.isAvailable else { return checked }
        guard let receiver = NSClassFromString(setter.className), object.isKind(of: receiver) else {
            return .unavailable(.receiverMismatch(class: setter.className))
        }
        let setSelector = NSSelectorFromString(setter.selector)
        let getSelector = NSSelectorFromString(getter.selector)
        guard let setMethod = unsafe class_getInstanceMethod(type(of: object), setSelector),
            let getMethod = unsafe class_getInstanceMethod(type(of: object), getSelector)
        else { return .unavailable(.selectorMissing(class: setter.className, selector: setter.selector)) }
        let set = unsafe unsafeBitCast(method_getImplementation(setMethod), to: Setter.self)
        let get = unsafe unsafeBitCast(method_getImplementation(getMethod), to: Getter.self)

        let before = get(object, getSelector)
        set(object, setSelector, value)
        guard get(object, getSelector) == value else {
            set(object, setSelector, before)
            return .unavailable(.readBackMismatch(selector: setter.selector))
        }
        return .available
    }
}
