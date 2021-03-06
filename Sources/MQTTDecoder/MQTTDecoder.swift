import NIO
import Foundation

//enum ParseError {
//    case
//}
enum ParseResult {
    case insufficientData
    case decoded(num: Int)
    case result(decoded:Int, packet: MQTTPacket)
}

fileprivate class MQTTParserState {
    internal var state: WaitingDataState = .firstByte
    internal var decoder: MQTTMessageDecoder = MQTTMessageDecoder()
    
    public var cumulationBuffer: ByteBuffer? = nil
    internal private(set) var curRemainlength: Int? = nil
    internal private(set) var curFixedHeader: MQTTPacketFixedHeader? = nil
    internal private(set) var curVariableHeader: MQTTPacketVariableHeader? = nil
    internal private(set) var curPayload: MQTTPacketPayload? = nil

    
    enum WaitingDataState {
        case firstByte
        case variableHeaderData
        case payloadData
    }

    func praseStep(_ buffer: inout ByteBuffer) throws -> ParseResult {
        switch self.state {
        case .firstByte:
            let (decoded, fixedheader) = try decoder.decodeFixedHeader(buffer: &buffer)
            
            guard decoded != 0, let fixedHeader = fixedheader else {
                return .insufficientData
            }

            if decoded > buffer.readableBytes {
                return .insufficientData
            }
            self.curFixedHeader = fixedheader
            self.curRemainlength = fixedHeader.remainingLength
            return updateState(curState: .firstByte, decoded: decoded)
            
        case .variableHeaderData:
            let (decoded, variableHeader) = try decoder.decodeVariableHeader(fixedHeader: curFixedHeader!, buffer: &buffer)
            self.curVariableHeader = variableHeader
            self.curRemainlength! -= decoded
            return updateState(curState: .variableHeaderData, decoded: decoded)
        case .payloadData:
            guard self.curRemainlength! >= 0 else {
                throw MQTTDecodeError.remainLengthLessThanZero
            }
            let (decoded, payload) = try decoder.decodePayloads(variableHeader: curVariableHeader, packetType: curFixedHeader!.messageType, remainLength: curRemainlength!, buffer: &buffer)
            self.curPayload = payload
            return updateState(curState: .payloadData, decoded: decoded)
        }
    }
    
    func reset() {
        self.state = .firstByte
        self.curRemainlength = nil
        self.curFixedHeader = nil
        self.curPayload = nil
        self.curVariableHeader = nil
    }
    
    func checkIfNeedMore(buffer: ByteBuffer) -> Bool {
        if self.state == .firstByte {
            // we need to check firstByte state when parse it
            return false
        }
        switch self.state {
        case .variableHeaderData:
            if let length = caculateVariableHeaderLength(buffer: buffer) {
                return buffer.readableBytes < length
            } else {
                return true
            }
        case .payloadData:
            switch self.curFixedHeader!.messageType {
            case .PUBLISH, .CONNEC, .SUBSCRIBE, .UNSUBSCRIBE:
                return buffer.readableBytes < self.curRemainlength!
            default:
                return false
            }
        default:
            return false
        }
    }
    
    func updateState(curState: WaitingDataState, decoded: Int) -> ParseResult {
        switch curState {
        case .firstByte:
            switch curFixedHeader!.messageType {
            case .PINGRESP, .PINGREQ, .DISCONNECT:
                let packet = MQTTPacket(fixedHeader: curFixedHeader!)
                reset()
                return .result(decoded: decoded, packet: packet)
            default:
                self.state = .variableHeaderData
                return .decoded(num: decoded)
            }

        case .variableHeaderData:
            switch curFixedHeader!.messageType {
            case .CONNACK, .PUBACK, .PUBREL:
                let packet = MQTTPacket(fixedHeader: curFixedHeader!, variableHeader: curVariableHeader!)
                reset()
                return .result(decoded: decoded, packet: packet)
            default:
                self.state = .payloadData
                return .decoded(num: decoded)
            }
        case .payloadData:
            let packet = MQTTPacket(fixedHeader: curFixedHeader!, variableHeader: curVariableHeader, payloads: curPayload)
            reset()
            return .result(decoded: decoded, packet: packet)
        }
    }
    
    func caculateVariableHeaderLength(buffer: ByteBuffer) -> Int? {
        func decodeMsbLsb(bytes: [UInt8]) -> Int {
            let result = bytes[0] << 8 | bytes[1]
            return Int(result)
        }
        
        switch self.curFixedHeader!.messageType {
        case .CONNEC:
            return 10
        case .PUBLISH:
            guard let topicLenBytes = buffer.getBytes(at: (buffer.readerIndex) ,length: 2) else {
                // we need to caclulate the length of publish packet's variableheader,the first two bytes
                // is the length of topic,if we cant get,means we need more data,so return max to let paraser
                // know there should be more data
                return nil
            }
            var res = 2
            res += decodeMsbLsb(bytes: topicLenBytes)
            if self.curFixedHeader!.qosLevel > .AT_MOST_ONCE {
                res += 2
            }
            return res
        case .SUBSCRIBE, .SUBACK, .UNSUBACK, .UNSUBSCRIBE, .PUBACK, .PUBREC, .PUBREL, .PUBCOMP:
            return 2
        default:
            return 0
        }
    }
}

public final class MQTTDecoder: ByteToMessageDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = MQTTPacket
    private var decoding: Bool = false
    private var newDataComing: Bool = false
    
    public var cumulationBuffer: ByteBuffer? {
        get {
            return self.parser.cumulationBuffer
        }
        set {
            self.parser.cumulationBuffer = newValue
        }
    }
    public init () {
        
    }

    private var shouldKeepingParse = false
    fileprivate var parser: MQTTParserState = MQTTParserState()
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)

        guard !self.decoding else {

            self.cumulationBuffer?.write(buffer: &buffer)

            return
        }

        self.decoding = true
        
        defer {
            self.decoding = false
        }

        if self.cumulationBuffer == nil {
            self.cumulationBuffer = buffer
        } else {
            self.cumulationBuffer?.write(buffer: &buffer)
        }
//
        do {
            try decodeMQTT(ctx: ctx)
            if !shouldKeepingParse {
                //TODO 适当的时候释放bufferByte
                self.cumulationBuffer = nil
            }
        }
        catch {
            self.cumulationBuffer = nil
            ctx.fireErrorCaught(error)
            ctx.close(promise: nil)
        }
        
    }
    
    func decodeMQTT(ctx: ChannelHandlerContext) throws {
        // i have thinked how to write that until i read the code from official http parser
        // its write, so i follow the solution of it
        var needmore = false
//       we wont change bufferSlice while parseStep
        parsing: while var bufferSlice = self.parser.cumulationBuffer, bufferSlice.readableBytes > 0 {
            guard !self.parser.checkIfNeedMore(buffer: bufferSlice) else {
                needmore = true
                break
            }
            let res = try self.parser.praseStep(&bufferSlice)
            switch res {
            case .insufficientData:
                needmore = true
                break parsing
            case let .decoded(decoded):
                self.cumulationBuffer?.moveReaderIndex(forwardBy: decoded)
            case let .result(decoded, packet):
                self.cumulationBuffer?.moveReaderIndex(forwardBy: decoded)
                ctx.fireChannelRead(wrapInboundOut(packet))
            }
        }
        shouldKeepingParse = self.parser.state != .firstByte || (self.parser.state == .firstByte && needmore)
    }
    
    // will remove in the future
    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        print("decod handle")
        return .needMoreData
    }
}
