//
//  SessionManager.swift
//
//
//  Created by Edon Valdman on 6/29/22.
//

import Foundation
import Combine
import WSPublisher

public final class OBSSessionManager: ObservableObject {
    public init() {
        self.wsPublisher = WebSocketPublisher()
    }
    
    public var wsPublisher: WebSocketPublisher
    private var observers = Set<AnyCancellable>()
    
    public var isConnected: Bool {
        wsPublisher.isConnected
    }
    
    @Published var isStudioModeEnabled: Bool = false
    @Published var currentProgramSceneName: String! = nil
    @Published var currentPreviewSceneName: String? = nil
    
    var currentSceneName: String! {
        currentPreviewSceneName ?? currentProgramSceneName
    }
    
    public var connectionStatus: AnyPublisher<Bool, Error> {
        return wsPublisher.publisher
            .map { event -> Bool? in
                switch event {
                case .connected:
                    return true
                case .disconnected:
                    return false
                default:
                    return nil
                }
            }
            // On fresh subscription, it'll push latest value.
            // If it's not .connected/.disconnected, replace with if it's connected
            .replaceNil(with: isConnected)
            // Don't push through duplicate values
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

// MARK: - Connections

extension OBSSessionManager {
    // TODO: Is it necessary for this to return a Bool?
    @discardableResult
    public func checkForConnection() throws -> Bool {
        if !isConnected {
            throw WebSocketPublisher.WSErrors.noActiveConnection
        }
        return wsPublisher.isConnected
    }
    
    public func persistConnectionData(_ connectionData: WebSocketPublisher.WSConnectionData) {
        try? UserDefaults.standard.set(encodable: connectionData, forKey: .connectionData)
    }
    
    public func loadConnectionData() -> WebSocketPublisher.WSConnectionData? {
        return try? UserDefaults.standard.decodable(WebSocketPublisher.WSConnectionData.self, forKey: .connectionData)
    }
    
    public func connect(using connectionData: WebSocketPublisher.WSConnectionData,
                        persistConnectionData: Bool = true,
                        events: OBSEnums.EventSubscription?) -> AnyPublisher<Void, Error> {
        // Set up listeners/publishers before starting connection.
        defer {
            wsPublisher.connect(using: connectionData)
        }
        
        
        // Once the connection is upgraded, the websocket server will immediately send an OpCode 0 `Hello` message to the client.
        return publisher(forFirstMessageOfType: OpDataTypes.Hello.self)
            
            // - The client listens for the `Hello` and responds with an OpCode 1 `Identify` containing all appropriate session parameters.
            
            //   - If there is an `authentication` field in the `messageData` object, the server requires authentication, and the steps in Creating an authentication string should be followed.
            //   - If there is no `authentication` field, the resulting `Identify` object sent to the server does not require an authentication string.
            //   - The client determines if the server's rpcVersion is supported, and if not it provides its closest supported version in Identify.
            .tryCompactMap { try $0.toIdentify(password: self.wsPublisher.password) }
            .map { data -> Message<OpDataTypes.Identify> in
                Message<OpDataTypes.Identify>.wrap(data: data)
            }
            .delay(for: .seconds(1), scheduler: DispatchQueue.main)
            .flatMap { self.wsPublisher.send($0) }
            
            // - The server receives and processes the `Identify` sent by the client.
            //   - If authentication is required and the Identify message data does not contain an authentication string, or the string is not correct, the connection is closed with WebSocketCloseCode::AuthenticationFailed
            //   - If the client has requested an rpcVersion which the server cannot use, the connection is closed with WebSocketCloseCode::UnsupportedRpcVersion. This system allows both the server and client to have seamless backwards compatability.
            //  - If any other parameters are malformed (invalid type, etc), the connection is closed with an appropriate close code.
            .flatMap { self.publisher(forFirstMessageOfType: OpDataTypes.Identified.self) }
            .tryFlatMap { _ in try self.getInitialData() }
            .handleEvents(receiveCompletion: { [weak self] result in
                switch result {
                case .finished:
//                    print("Success:", result)
//                    self?.isConnected = true
                    
                    if persistConnectionData {
                        self?.persistConnectionData(connectionData)
                    }
                    try? self?.addObservers()
                    
                case .failure(let err):
//                    print("*3* Failure to connect:", err)
//                    self?.isConnected = false
                    self?.wsPublisher.disconnect()
                }
            })
            .eraseToAnyPublisher()
    }
    
    // TODO: Keep or toss this?
    public func getInitialData() throws -> AnyPublisher<Void, Error> {
        // Uses direct calls to `wsPub.sendRequest` because local one would be waiting until connected
        let studioModeReq = try sendRequest(OBSRequests.GetStudioModeEnabled())
            .map(\.studioModeEnabled)
            .handleEvents(receiveOutput: { [weak self] isStudioModeEnabled in
                self?.isStudioModeEnabled = isStudioModeEnabled
            })
            .tryFlatMap { isStudioModeEnabled -> AnyPublisher<Void, Error> in
                guard isStudioModeEnabled else { return Future(withValue: ()).eraseToAnyPublisher() }
                
                return try self.sendRequest(OBSRequests.GetCurrentPreviewScene())
                    .map(\.currentPreviewSceneName)
                    .handleEvents(receiveOutput: { [weak self] currentPreviewScene in
                        self?.currentPreviewSceneName = currentPreviewScene
                    }).asVoid()
            }.asVoid()
        
        let currentProgramReq = try self.sendRequest(OBSRequests.GetCurrentProgramScene())
            .map(\.currentProgramSceneName)
            .handleEvents(receiveOutput: { [weak self] currentProgramScene in
                self?.currentProgramSceneName = currentProgramScene
            }).asVoid()
        
        return Publishers.Zip(studioModeReq, currentProgramReq)
            .asVoid()
    }
    
    private func addObservers() throws {
        try listenForEvent(OBSEvents.StudioModeStateChanged.self, firstOnly: false)
            .map(\.studioModeEnabled)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] isStudioModeEnabled in
                self?.currentPreviewSceneName = isStudioModeEnabled ? self?.currentProgramSceneName : nil
                self?.isStudioModeEnabled = isStudioModeEnabled
            })
            .store(in: &observers)
        
        try listenForEvent(OBSEvents.CurrentProgramSceneChanged.self, firstOnly: false)
            .map(\.sceneName)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] newProgramSceneName in
                self?.currentProgramSceneName = newProgramSceneName
            }).store(in: &observers)
        
        try listenForEvent(OBSEvents.CurrentPreviewSceneChanged.self, firstOnly: false)
            .map(\.sceneName)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] newPreviewSceneName in
                self?.currentPreviewSceneName = newPreviewSceneName
            }).store(in: &observers)
    }
}

// MARK: - Observable Publishers

public extension OBSSessionManager {
    var publisherAnyOpCode: AnyPublisher<UntypedMessage, Error> {
        return wsPublisher.publisher
            .tryFilter { event throws -> Bool in
                switch event {
                case .disconnected(let wsCloseCode, let reason):
                    let obsCloseCode = OBSEnums.CloseCode(rawValue: wsCloseCode.rawValue)
                    throw Errors.disconnected(obsCloseCode, reason)
                    
                default:
                    // Filters through if the publisher is connected
                    return self.wsPublisher.isConnected
                }
            }
            .compactMap { msg -> UntypedMessage? in
                switch msg {
//                case .data(let d):
                    // MsgPack?
//                    return nil
                case .string(let str):
                    return try? JSONDecoder.decode(UntypedMessage.self, from: str)
                default:
                    return nil
                }
            }.eraseToAnyPublisher()
    }
    
    var publisherAnyOpCodeData: AnyPublisher<OBSOpData, Error> {
        return publisherAnyOpCode
            .tryCompactMap { try $0.messageData() }
            .eraseToAnyPublisher()
    }
    
    /// Creates a `Publisher` that publishes all `OBSOpData` messages of the provided type. It doesn't complete on its own. It continues waiting until the subscriber is closed off.
    /// - Parameter type: The type of message for the created `Publisher` to publish. i.e. `OpDataTypes.Hello.self`
    /// - Returns: A `Publisher` that publishes all `OBSOpData` messages of the provided type.
    func publisher<Op: OBSOpData>(forAllMessagesOfType type: Op.Type) -> AnyPublisher<Op, Error> {
        return publisherAnyOpCode
            .filter { $0.operation == Op.opCode }
            .tryCompactMap { try $0.messageData() as? Op }
            .eraseToAnyPublisher()
    }
    
    /// Creates a `Publisher` that publishes the first `OBSOpData` message of the provided type. It completes after the first message.
    /// - Parameter type: The type of message for the created `Publisher` to publish. i.e. `OpDataTypes.Hello.self`
    /// - Returns: A `Publisher` that publishes the first `OBSOpData` message of the provided type.
    func publisher<Op: OBSOpData>(forFirstMessageOfType type: Op.Type) -> AnyPublisher<Op, Error> {
        return publisher(forAllMessagesOfType: type)
            .first() // Finishes the stream after allowing 1 of the correct type through
            .eraseToAnyPublisher()
    }
    
    func publisher<R: OBSRequest>(forResponseTo req: R, withID id: String? = nil) -> AnyPublisher<R.ResponseType, Error> {
        return publisher(forAllMessagesOfType: OpDataTypes.RequestResponse.self)
            .tryFilter { resp throws -> Bool in
                // code == 100
                guard resp.status.result else { throw Errors.requestResponse(resp.status) }
                return true
            }
            // If the id passed in isn't nil, then make sure it matches the response id.
            // Otherwise, let any response pass through
            .filter { id != nil ? id == $0.id : true }
            .map(\.data)
            .replaceNil(with: .emptyObject)
            .tryCompactMap { try $0.toCodable(req.type.ResponseType.self) }
            .first() // Finishes the stream after allowing 1 of the correct type through
            .eraseToAnyPublisher()
    }
}

// MARK: - Sending Requests

public extension OBSSessionManager {
    func sendRequest<R: OBSRequest>(_ request: R) throws -> AnyPublisher<R.ResponseType, Error> {
        try checkForConnection()
        guard let type = request.typeEnum,
              let body = OpDataTypes.Request(type: type, id: UUID().uuidString, request: request) else {
            return Fail(error: Errors.buildingRequest)
                .eraseToAnyPublisher()
        }
        
        let msg = Message<OpDataTypes.Request>(data: body)
        return wsPublisher.send(msg)
            .flatMap { self.publisher(forResponseTo: request, withID: msg.data.id) }
            .eraseToAnyPublisher()
    }
    
    // TODO: Create docs here. Note that not all provided requests have to be the same kind.
    // Instead, it's an array of pre-wrapped Request messages.
    func sendRequestBatch(executionType: OBSEnums.RequestBatchExecutionType? = .serialRealtime,
                          requests: [OpDataTypes.RequestBatch.Request?]) throws -> AnyPublisher<[String: OBSRequestResponse], Error> {
        try checkForConnection()
        
        let msgBodyToSend = OpDataTypes.RequestBatch(id: UUID().uuidString, executionType: executionType, requests: requests.compactMap { $0 })
        let msgToSend = Message<OpDataTypes.RequestBatch>(data: msgBodyToSend)
        
        return wsPublisher.send(msgToSend)
            .flatMap { self.publisher(forAllMessagesOfType: OpDataTypes.RequestBatchResponse.self) }
            .filter { [msgBodyToSend] receivedMsgBody in receivedMsgBody.id == msgBodyToSend.id }
            .first() // Finishes the stream after allowing 1 of the correct type through
            .tryMap { try $0.mapResults() }
            .eraseToAnyPublisher()
    }
    
    /// <#Description#>
    /// - Parameters:
    ///   - executionType: <#executionType description#>
    ///   - requests: A `Dictionary` of `String`s to `OBSRequest`s. All `OBSRequest`s in `requests` must be of the same type. The `String`s are the IDs of the `OBSRequest`s, and are matched up with their responses in the returned `Dictionary`.
    /// - Throws: If `wsPublisher` is not currently connected, a `WebSocketPublisher.WSErrors.noActiveConnection` error will be thrown.
    /// - Returns: A `Publisher` containing a `Dictionary` of Request IDs to their matching `OBSRequestResponse`s.
    func sendRequestBatch<R: OBSRequest>(executionType: OBSEnums.RequestBatchExecutionType? = .serialRealtime,
                                         requests: [String: R]) throws -> AnyPublisher<[String: R.ResponseType], Error> {
        //        guard requests.allSatisfy { $0.type == R.typeEnum } else { return }
        
        return try sendRequestBatch(executionType: executionType,
                                    requests: requests.map { (id, req) -> OpDataTypes.RequestBatch.Request? in
                                        return OpDataTypes.Request(
                                            type: req.typeEnum!,
                                            id: id,
                                            request: req
                                        )?.forBatch()
                                    })
            .map { respDict in
                respDict.compactMapValues { $0 as? R.ResponseType }
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Listening for OBSEvents

public extension OBSSessionManager {
    func listenForEvent(_ eventType: OBSEvents.AllTypes, firstOnly: Bool) throws -> AnyPublisher<OBSEvent, Error> {
        try checkForConnection()
        
        let pub = publisher(forAllMessagesOfType: OpDataTypes.Event.self)
            .filter { $0.type == eventType }
        
        if firstOnly {
            return pub
                .first() // Finishes the stream after allowing 1 of the correct type through
                .tryCompactMap { try OBSEvents.AllTypes.event(ofType: $0.type, from: $0.data) }
                .eraseToAnyPublisher()
        } else { // .continuously
            return pub
                .tryCompactMap { try OBSEvents.AllTypes.event(ofType: $0.type, from: $0.data) }
                .eraseToAnyPublisher()
        }
    }
    
    func listenForEvent<E: OBSEvent>(_ eventType: E.Type, firstOnly: Bool) throws -> AnyPublisher<E, Error> {
        guard let type = eventType.typeEnum else { throw Errors.failedEventTypeConversion }
        return try listenForEvent(type, firstOnly: firstOnly)
            .compactMap { $0 as? E }
            .eraseToAnyPublisher()
    }
    
    /// Doesn't complete on its own. It continues listening for any instances of the provided `OBSEvent` types until the subscriber is closed off.
    /// - Parameter types: <#types description#>
    /// - Throws: <#description#>
    /// - Returns: <#description#>
    func listenForEvents(_ types: OBSEvents.AllTypes...) throws -> AnyPublisher<OBSEvent, Error> {
        try checkForConnection()
        
        let pubs = types.map { t in
            publisher(forAllMessagesOfType: OpDataTypes.Event.self)
                .filter { $0.type == t }
                .tryCompactMap { try OBSEvents.AllTypes.event(ofType: $0.type, from: $0.data) }
            //                .eraseToAnyPublisher()
        }
        return Publishers.MergeMany(pubs)
            .eraseToAnyPublisher()
    }
}

extension OBSSessionManager {
    public struct ConnectionData: Codable {
        static let encodingProtocolHeaderKey = "Sec-WebSocket-Protocol"
        
        public init(scheme: String = "ws", ipAddress: String, port: Int, password: String?, encodingProtocol: MessageEncoding = .json) {
            self.scheme = scheme
            self.ipAddress = ipAddress
            self.port = port
            self.password = password
            self.encodingProtocol = encodingProtocol
        }
        
        public var scheme: String
        public var ipAddress: String
        public var port: Int
        public var password: String?
        public var encodingProtocol: MessageEncoding?
        
        public init?(fromUrl url: URL) {
            self.init(fromUrlRequest: URLRequest(url: url))
        }
        
        public init?(fromUrlRequest request: URLRequest) {
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme,
                  let ipAddress = components.host,
                  let port = components.port else { return nil }
            
            self.scheme = scheme
            self.ipAddress = ipAddress
            self.port = port
            
            let path = components.path.replacingOccurrences(of: "/", with: "")
            self.password = path.isEmpty ? nil : path
            
            if let encodingStr = request.value(forHTTPHeaderField: Self.encodingProtocolHeaderKey),
               let encoding = MessageEncoding(rawValue: encodingStr) {
                self.encodingProtocol = encoding
            }
        }
        
        public var urlString: String {
            var str = "\(scheme)://\(ipAddress):\(port)"
            if let pass = password, !pass.isEmpty {
                str += "/\(pass)"
            }
            return str
        }
        
        public var url: URL? {
            return URL(string: urlString)
        }
        
        public var urlRequest: URLRequest? {
            guard let url = self.url else { return nil }
            var req = URLRequest(url: url)
            
            if let encoding = self.encodingProtocol {
                req.addValue(encoding.rawValue, forHTTPHeaderField: Self.encodingProtocolHeaderKey)
            }
            return req
        }
        
        public enum MessageEncoding: String, Codable {
            /// JSON over text frames
            case json = "obswebsocket.json"
            /// MsgPack over binary frames
            case msgPack = "obswebsocket.msgpack"
        }
    }
}

// MARK: - Errors

internal extension OBSSessionManager {
    enum Errors: Error {
        case disconnected(_ closeCode: OBSEnums.CloseCode?, _ reason: String?)
        
        /// Thrown during authentication process when OBS requires a password, but the user didn't supply one.
        case missingPasswordWhereRequired
        
        case requestResponse(OpDataTypes.RequestResponse.Status)
        case buildingRequest
        case sendingRequest
        case weakSelfNil
        case failedEventTypeConversion
        
        public var errorMessage: String? {
            switch self {
            case .disconnected(_, let reason):
                return reason ?? "Connection has been closed"
            case .missingPasswordWhereRequired:
                return "Password is required by server"
                
            default:
                return nil
            }
        }
    }
}
