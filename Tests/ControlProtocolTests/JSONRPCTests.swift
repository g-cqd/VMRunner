import Foundation
import Testing

@testable import ControlProtocol

/// Strict JSON-RPC 2.0: what is a request, what is answered at once and with which standard error, and how an answer is written.
struct JSONRPCTests {
    private func parse(_ text: String) -> RPCParse { RPCMessage.parse(Data(text.utf8)) }

    private func errorCode(_ text: String) -> Int? {
        guard case .invalid(let response) = parse(text) else { return nil }
        return response.error?.code
    }

    @Test
    func aWellFormedRequestIsReadWithItsIdMethodAndParams() {
        let parsed = parse(#"{"jsonrpc":"2.0","id":7,"method":"machines.state","params":{"token":"t","machine":"m","force":true}}"#)
        let expected = RPCRequest(
            id: .number(7), method: "machines.state", params: ["token": .string("t"), "machine": .string("m"), "force": .bool(true)])
        #expect(parsed == .request(expected))
        #expect(parse(#"{"jsonrpc":"2.0","id":"a","method":"m"}"#) == .request(RPCRequest(id: .string("a"), method: "m")))
        #expect(parse(#"{"jsonrpc":"2.0","id":null,"method":"m"}"#) == .request(RPCRequest(id: .null, method: "m")))
    }

    @Test
    func aRequestWithoutAnIdIsANotification() {
        #expect(parse(#"{"jsonrpc":"2.0","method":"machines.list"}"#) == .notification(method: "machines.list"))
    }

    @Test(arguments: ["{", "not json", #"{"jsonrpc":"2.0","#, ""])
    func textThatIsNotJSONIsAParseError(text: String) {
        #expect(errorCode(text) == -32700)
    }

    @Test
    func aBatchIsRefusedWithTheStandardInvalidRequestError() throws {
        guard case .invalid(let response) = parse(#"[{"jsonrpc":"2.0","id":1,"method":"machines.list"}]"#) else {
            Issue.record("a batch must be refused")
            return
        }
        #expect(response.id == .null)
        #expect(response.error?.code == -32600)
        #expect(response.error?.message.contains("batches are not supported") == true)
        #expect(errorCode("[]") == -32600)
    }

    @Test(arguments: [
        #"5"#, #""text""#, #"{"id":1,"method":"m"}"#, #"{"jsonrpc":"1.0","id":1,"method":"m"}"#,
        #"{"jsonrpc":"2.0","id":1}"#, #"{"jsonrpc":"2.0","id":1,"method":""}"#, #"{"jsonrpc":"2.0","id":1,"method":3}"#,
        #"{"jsonrpc":"2.0","id":1.5,"method":"m"}"#, #"{"jsonrpc":"2.0","id":true,"method":"m"}"#,
        #"{"jsonrpc":"2.0","id":{},"method":"m"}"#, #"{"jsonrpc":"2.0","id":1,"method":"m","extra":0}"#,
    ])
    func malformedRequestsAreInvalidRequests(text: String) {
        #expect(errorCode(text) == -32600, "\(text)")
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":1,"method":"m","params":[]}"#, #"{"jsonrpc":"2.0","id":1,"method":"m","params":"x"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":1}}"#, #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":null}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":{}}}"#,
    ])
    func paramsThatAreNotAnObjectOfStringsAndBooleansAreInvalidParams(text: String) {
        guard case .invalid(let response) = parse(text) else {
            Issue.record("\(text) must be refused")
            return
        }
        #expect(response.error?.code == -32602, "\(text)")
        #expect(response.id == .number(1), "the answer carries the request's id")
    }

    @Test(arguments: [9, 100, 600, 20_000])
    func linesNestedTooDeeplyAreRefusedWithoutBeingParsed(depth: Int) {
        let objects = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(errorCode(objects) == -32600, "objects \(depth) deep")
        #expect(errorCode(arrays) == -32600, "arrays \(depth) deep")
        #expect(errorCode(String(repeating: "[", count: depth)) == -32600, "an unfinished line is refused too")
    }

    @Test
    func bracketsInsideStringsDoNotCountAsNesting() {
        let text = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":"[[[[[[[[[[[[[[[[[[[[ \"{{{{{{{{{{{{ \\"}}"#
        #expect(
            parse(text)
                == .request(RPCRequest(id: .number(1), method: "m", params: ["a": .string(#"[[[[[[[[[[[[[[[[[[[[ "{{{{{{{{{{{{ \"#)])))
    }

    @Test
    func anAnswerIsOneLineOfJSONWithTheRequestsId() throws {
        let result = RPCResponse(id: .string("x\"y"), result: Data(#"{"a":[1,2]}"#.utf8)).encoded()
        #expect(result.last == UInt8(ascii: "\n"))
        #expect(!result.dropLast().contains(UInt8(ascii: "\n")))
        let decoded = try #require(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        #expect(decoded["jsonrpc"] as? String == "2.0")
        #expect(decoded["id"] as? String == "x\"y")
        #expect((decoded["result"] as? [String: Any])?["a"] as? [Int] == [1, 2])

        let failure = RPCResponse(id: .number(3), error: .notPermitted.with("a \"quoted\" detail")).encoded()
        let error = try #require(try JSONSerialization.jsonObject(with: failure) as? [String: Any])
        #expect(error["id"] as? Int == 3)
        let body = try #require(error["error"] as? [String: Any])
        #expect(body["code"] as? Int == -32001)
        #expect(body["message"] as? String == "Not permitted: a \"quoted\" detail")
        #expect(!error.keys.contains("result"))
    }

    @Test
    func aNullIdIsWrittenAsNull() throws {
        let line = RPCResponse(id: .null, error: .parseError).encoded()
        let decoded = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(decoded["id"] is NSNull)
    }
}
