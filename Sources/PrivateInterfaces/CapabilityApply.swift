package import Foundation

extension CapabilityEntry {
    private typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias Getter = @convention(c) (AnyObject, Selector) -> Bool

    /// Sets the switch on `object` and reads it back. The object must be an instance of the setter's class and of the getter's
    /// class, the methods are taken from those registered classes, and the contract must hold now (`status(in:)`); otherwise
    /// nothing is called. An object whose own class gives either selector another type is refused too. If the value read back is
    /// not the value set, the value the switch had is put back and the capability is reported unavailable.
    package func apply(_ value: Bool, to object: NSObject, in context: PrivateCapabilityContext) -> PrivateCapabilityStatus {
        let checked = status(in: context)
        guard checked.isAvailable else { return checked }
        guard let receiver = NSClassFromString(setter.className), object.isKind(of: receiver) else {
            return .unavailable(.receiverMismatch(class: setter.className))
        }
        guard let reader = NSClassFromString(getter.className), object.isKind(of: reader) else {
            return .unavailable(.receiverMismatch(class: getter.className))
        }
        let setSelector = NSSelectorFromString(setter.selector)
        let getSelector = NSSelectorFromString(getter.selector)
        guard let setMethod = unsafe class_getInstanceMethod(receiver, setSelector),
            let getMethod = unsafe class_getInstanceMethod(reader, getSelector)
        else { return .unavailable(.selectorMissing(class: setter.className, selector: setter.selector)) }
        // The class the messages go to, which `type(of:)` does not give for a subclass made at run time.
        let dispatched: AnyClass = object_getClass(object) ?? type(of: object)
        for contract in [setter, getter] {
            let found = Self.encoding(in: dispatched, selector: NSSelectorFromString(contract.selector))
            guard found == contract.encoding else {
                return .unavailable(.encodingMismatch(selector: contract.selector, expected: contract.encoding, found: found ?? ""))
            }
        }
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

    /// The type encoding, without its offsets, that instances of `type` give `selector`; `nil` when they have no such method.
    private static func encoding(in type: AnyClass, selector: Selector) -> String? {
        guard let method = unsafe class_getInstanceMethod(type, selector), let raw = unsafe method_getTypeEncoding(method) else {
            return nil
        }
        return unsafe String(cString: raw).filter { !$0.isNumber }
    }
}
