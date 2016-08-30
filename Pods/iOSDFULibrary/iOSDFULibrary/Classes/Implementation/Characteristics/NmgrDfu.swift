/*
 * Copyright (c) 2016, Nordic Semiconductor
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this
 * software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
 * USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import CoreBluetooth

internal class NmgrDfuChr: NSObject, CBPeripheralDelegate {
    static private let UUID = CBUUID(string: "DA2E7828-FBCE-4E01-AE9E-261174997C48")
    
    static func matches(characteristic:CBCharacteristic) -> Bool {
        return characteristic.UUID.isEqual(UUID)
    }
    
    private let PacketSize = 76
    
    private var characteristic:CBCharacteristic
    private var logger:LoggerHelper

    /// Current progress in percents (0-99).
    private var progress = 0
    private var startTime:CFAbsoluteTime?
    private var lastTime:CFAbsoluteTime?
    private var success:NmgrServiceCallback?
    private var report:NmgrServiceErrorCallback?
    
    private var proceed:ProgressCallback?
    private var Request:NmgrRequest?
    private var uploadStartTime:CFAbsoluteTime?
    private var resetSent:Bool = false
    private var firmwareSize:Int = 0
    
    //Offset of firmware data to be sent, generally response specifies this
    private(set) var offset = 0
    
    init(_ characteristic:CBCharacteristic, _ logger:LoggerHelper) {
        self.characteristic = characteristic
        self.logger = logger
    }
    
    var valid:Bool {
        return characteristic.properties.contains(CBCharacteristicProperties.WriteWithoutResponse)
    }
 
    var read_valid:Bool {
        return characteristic.properties.contains(CBCharacteristicProperties.Read)
    }
    
    // Nmgr Flags/Opcode/Group/Id Enums
    enum NmgrFlags : UInt8 {
        case Default = 0
        
        var code:UInt8 {
            return rawValue
        }
    }
    
    enum NmgrOpCode : UInt8 {
        case Read       = 0
        case ReadResp   = 1
        case Write      = 2
        case WriteRsp   = 3
        
        var code:UInt8 {
            return rawValue
        }
    }
    
    enum NmgrGrp : UInt16 {
        case Default    = 0
        case Image      = 1
        case Stats      = 2
        case Config     = 3
        case Logs       = 4
        case Crash      = 5
        case Peruser    = 64
        
        var code:UInt16 {
            return rawValue
        }
    }
    

    enum OpDfu : UInt8 {
        case List       = 0
        case Upload     = 1
        case Boot       = 2
        case File       = 3
        case List2      = 4
        case Boot2      = 5
        case Corelist   = 6
        case Coreload   = 7
        
        var code:UInt8 {
            return rawValue
        }
    }
    
    /* Group Ids only used for default group commands */
    enum DefGrp : UInt8 {
        case Echo           = 0
        case ConsEchoCtrl   = 1
        case Taskstats      = 2
        case Mpstats        = 3
        case DatetimeStr    = 4
        case Reset          = 5
        
        var code:UInt8 {
            return rawValue
        }
    }
    
    enum ReturnCode : UInt16 {
        case EOk        = 0
        case EUnknown   = 1
        case ENomem     = 2
        case EInval     = 3
        case ETimeout   = 4
        case ENonent    = 5
        case EPeruser   = 256
        
        var description:String {
            switch self {
                case .EOk: return "Success"
                case .EUnknown: return "Unknown Error: Command might not be supported"
                case .ENomem:  return "Out of memory"
                case .EInval: return "Device is in invalid state"
                case .ETimeout: return "Operation Timeout"
                case .ENonent: return "Enoent"
                case .EPeruser: return "Peruser"
            }
        }
        
        var code:UInt16 {
            return rawValue
        }
    }
    
    struct nmgrPacket {
        var Op: NmgrOpCode
        var Flags: NmgrFlags
        var Len: UInt16
        var Group:NmgrGrp
        var Seq:UInt8
        var Id:UInt8
        var data: NSData
       
        init?(Op: NmgrOpCode, Flags: NmgrFlags, Len: UInt16, Group: NmgrGrp,
             Seq:UInt8, Id: UInt8, data: NSData) {
            
            self.Op    = NmgrOpCode.Write
            self.Flags = NmgrFlags.Default
            self.Len   = 0
            self.Group = NmgrGrp.Default
            self.Seq   = 0
            self.Id    = 0
            self.data  = data
            
            // Back to the passed values
            self.Op    = Op
            self.Flags = Flags
            self.Len   = Len
            self.Group = Group
            self.Seq   = Seq
            self.data  = data
            self.Id    = Id
        }
        
        struct ArchivedNmgrPacket {
            var Op   : UInt8
            var Flags: UInt8
            var Len  : UInt16
            var Group: UInt16
            var Seq  : UInt8
            var Id   : UInt8
        }
        
        func encode(data: NSData) -> NSData {
            
            var archivedNmgrPkt = ArchivedNmgrPacket(
                Op:self.Op.code,
                Flags:self.Flags.code,
                Len:self.Len.byteSwapped,
                Group:self.Group.code.byteSwapped,
                Seq:self.Seq,
                Id: self.Id
            )

            let nmgrPacket = NSMutableData(capacity: 8)!
            
            nmgrPacket.appendBytes(&archivedNmgrPkt.Op, length: sizeofValue(archivedNmgrPkt.Op))
            nmgrPacket.appendBytes(&archivedNmgrPkt.Flags, length: sizeofValue(archivedNmgrPkt.Flags))
            nmgrPacket.appendBytes(&archivedNmgrPkt.Len, length: sizeofValue(archivedNmgrPkt.Len))
            nmgrPacket.appendBytes(&archivedNmgrPkt.Group, length: sizeofValue(archivedNmgrPkt.Group))
            nmgrPacket.appendBytes(&archivedNmgrPkt.Seq, length: sizeofValue(archivedNmgrPkt.Seq))
            nmgrPacket.appendBytes(&archivedNmgrPkt.Id, length: sizeofValue(archivedNmgrPkt.Id))
            
            nmgrPacket.appendData(data)
            
            return nmgrPacket
        }
        
        func decode(data: NSData) -> nmgrPacket {
            
            var Op:UInt8 = 0
            var Flags:UInt8 = 0
            var bytesReceived:UInt16 = 0
            var Group:UInt16 = 0
            var Seq:UInt8 = 0
            var Id:UInt8 = 0
            var pktData = NSData()
            
            data.getBytes(&Op, range: NSRange(location: 0, length: 1))
            data.getBytes(&Flags, range: NSRange(location: 1, length: 1))
            data.getBytes(&bytesReceived, range: NSRange(location: 2, length: 2))
            bytesReceived = (UInt16(bytesReceived)).byteSwapped
            
            data.getBytes(&Group, range: NSRange(location: 4, length: 2))
            Group = (UInt16(Group)).byteSwapped
            
            data.getBytes(&Seq, range: NSRange(location: 6, length: 1))
            data.getBytes(&Id, range: NSRange(location: 7, length: 1))
            pktData = data.subdataWithRange(NSRange(location: 8, length:Int(bytesReceived)))
            
            NSLog("Received Nmgr Notification Response: Op:\(Op) Flags:\(Flags) Len:\(bytesReceived) Group:\(Group) Seq:\(Seq) Id:\(Id) data:\(pktData)")
            
            return nmgrPacket(Op:NmgrOpCode(rawValue: Op)!,
                              Flags:NmgrFlags(rawValue: Flags)!,
                              Len: bytesReceived,
                              Group: NmgrGrp(rawValue: Group)!,
                              Seq: Seq,
                              Id: Id,
                              data: pktData)!
        }
    }
    
    enum NmgrRequest {
        case Upload
        case Activate
        case Reset
        
        var req : nmgrPacket {
            var nmgrReq:nmgrPacket
            switch self {
            case .Upload:
                nmgrReq = nmgrPacket(Op: NmgrOpCode.Write,
                                     Flags:NmgrFlags.Default,
                                     Len: 0,
                                     Group:NmgrGrp.Image,
                                     Seq:0,
                                     Id:OpDfu.Upload.code,
                                     data: NSData()
                )!
                
            case .Activate:
                nmgrReq = nmgrPacket(Op: NmgrOpCode.Write,
                                     Flags:NmgrFlags.Default,
                                     Len: 0,
                                     Group:NmgrGrp.Image,
                                     Seq:0,
                                     Id:OpDfu.Boot2.code,
                                     data: NSData()
                )!
                
            case .Reset:
                nmgrReq = nmgrPacket(Op: NmgrOpCode.Write,
                                     Flags:NmgrFlags.Default,
                                     Len: 0,
                                     Group:NmgrGrp.Default,
                                     Seq:0,
                                     Id:DefGrp.Reset.code,
                                     data: NSData()
                )!
            }
            
            return nmgrReq
        }
        
        var description : String {
            switch self {
            case .Upload:
                return "Upload (OpCode = \(NmgrOpCode.Write.rawValue) Group = \(NmgrGrp.Image.rawValue) Id = \(OpDfu.Upload.code))"
            case .Activate:
                return "Activate (OpCode = \(NmgrOpCode.Write.rawValue) Group = \(NmgrGrp.Image.rawValue) Id = \(OpDfu.Boot2.code))"
            case .Reset:
                return "Reset (OpCode = \(NmgrOpCode.Write.rawValue) Group = \(NmgrGrp.Default.rawValue) Id = \(DefGrp.Reset.code))"
            }
        }
    }
    
    
    struct NmgrResponse {
        var nmgrRsp:nmgrPacket
        
        init?(_ data:NSData) {
            nmgrRsp = nmgrPacket(Op:NmgrOpCode.Write,
                                 Flags:NmgrFlags.Default,
                                 Len: 0,
                                 Group:NmgrGrp.Image,
                                 Seq:0,
                                 Id:OpDfu.Upload.code,
                                 data: data
            )!
            nmgrRsp = nmgrRsp.decode(data)
        }
        
        var description:String {
            return "Nmgr Response (Op Code = \(nmgrRsp.Op.rawValue) Group = \(nmgrRsp.Group.rawValue) Id = \(nmgrRsp.Id))"
        }
    }
    
    
    /**
     Sends the whole content of the data object.
     
     - parameter data: the data to be sent
     */
    func sendInitPacket(data:NSData, onSuccess success:NmgrServiceCallback?, onError report:NmgrServiceErrorCallback?) {
        // Get the peripheral object
        let peripheral = characteristic.service.peripheral
        
        var pkt:NSData
        var packetLength:UInt16
        
        (pkt, packetLength) = createNmgrDFUPacket(data)
    
        if pkt.length == 0 {
            report?(error:DFUError.InitPacketRequired, withMessage:"Init Packet creation failed")
        }
        
        logger.v("Init Pkt :: Writing to characteristic \(NmgrDfuChr.UUID.UUIDString)...")
        logger.d("peripheral.writeValue(0x\(pkt.hexString), forCharacteristic: \(NmgrDfuChr.UUID.UUIDString), type: WithoutResponse)")
        peripheral.writeValue(pkt, forCharacteristic: characteristic, type: CBCharacteristicWriteType.WithoutResponse)
        success?()
    }
    
    func firmwareJSONBase64Encode(data: NSData) -> NSData {

        var initPktDatabase64Encoded = data.base64EncodedStringWithOptions(NSDataBase64EncodingOptions(rawValue: 0))
        var jsonDict:NSMutableDictionary = NSMutableDictionary()
    
        jsonDict.setValue(offset, forKey: "off")
        if offset == 0 {
            jsonDict.setValue(firmwareSize, forKey: "len")
        }
        jsonDict.setValue(initPktDatabase64Encoded, forKey: "data")
        
        var jsonData = try! NSJSONSerialization.dataWithJSONObject(jsonDict, options: NSJSONWritingOptions(rawValue: 0))
        var packetNSString = NSString(data: jsonData, encoding: NSUTF8StringEncoding) as! NSString!
        if NSJSONSerialization.isValidJSONObject(packetNSString) {
            do {
                _ = try NSJSONSerialization.dataWithJSONObject(packetNSString, options: NSJSONWritingOptions(rawValue: 0))
            } catch {
                exit(1)
            }
        }
        
        NSLog("JSON payload:\(packetNSString)")
        
        return packetNSString.dataUsingEncoding(NSUTF8StringEncoding)!
    }
    
    func createNmgrDFUPacket(data: NSData) -> (NSData, UInt16) {
        
        // Data may be sent in up-to-180-bytes packets
        var bytesToSend:Int = 0
        var remainingBytes = data.length - offset
        
        if offset == 0 {
            firmwareSize = data.length
            // Initialize Timers
            startTime = CFAbsoluteTimeGetCurrent()
            lastTime = startTime
        }
        
        if  offset >= firmwareSize {
            return (NSData(),0)
        }
        
        if (remainingBytes/PacketSize > 0) {
            bytesToSend = PacketSize
        } else {
            bytesToSend = remainingBytes%PacketSize
        }
        
        let packetLength = min(bytesToSend, PacketSize)
        var reqData = data.subdataWithRange(NSRange(location: offset, length: packetLength))
        
        return createNmgrPacket(NmgrRequest.Upload.req, data: firmwareJSONBase64Encode(reqData))
    }
    
    func imgBoot2JSONEncode(buildId: NSData) -> NSData {
        
        var buildIdbase64Encoded = buildId.base64EncodedStringWithOptions(NSDataBase64EncodingOptions(rawValue: 0))
        var jsonDict:NSMutableDictionary = NSMutableDictionary()
        
        jsonDict.setValue(buildIdbase64Encoded, forKey: "test")
        
        var jsonData = try! NSJSONSerialization.dataWithJSONObject(jsonDict, options: NSJSONWritingOptions(rawValue: 0))
        var packetNSString = NSString(data: jsonData, encoding: NSUTF8StringEncoding) as! NSString!
        
        if NSJSONSerialization.isValidJSONObject(packetNSString) {
            do {
                _ = try NSJSONSerialization.dataWithJSONObject(packetNSString, options: NSJSONWritingOptions(rawValue: 0))
            } catch {
                exit(1)
            }
        }
        
        NSLog("Pkt Str:\(packetNSString)")
        
        return packetNSString.dataUsingEncoding(NSUTF8StringEncoding)!
    }
    
    func imgBootJSONEncode(img: NSData) -> NSData {
        
        var initPktDatabase64Encoded = img.base64EncodedStringWithOptions(NSDataBase64EncodingOptions(rawValue: 0))
        var jsonDict:NSMutableDictionary = NSMutableDictionary()
        
        jsonDict.setValue(img, forKey: "test")
        
        var jsonData = try! NSJSONSerialization.dataWithJSONObject(jsonDict, options: NSJSONWritingOptions(rawValue: 0))
        var packetNSString = NSString(data: jsonData, encoding: NSUTF8StringEncoding) as! NSString!
        
        if NSJSONSerialization.isValidJSONObject(packetNSString) {
            do {
                _ = try NSJSONSerialization.dataWithJSONObject(packetNSString, options: NSJSONWritingOptions(rawValue: 0))
            } catch {
                exit(1)
            }
        }
        
        return packetNSString.dataUsingEncoding(NSUTF8StringEncoding)!
    }
    
    func resetJSONEncode() -> NSData {
        
        var jsonDict:NSMutableDictionary = NSMutableDictionary()
        var jsonData = try! NSJSONSerialization.dataWithJSONObject(jsonDict, options: NSJSONWritingOptions(rawValue: 0))
        var packetNSString = NSString(data: jsonData, encoding: NSUTF8StringEncoding) as! NSString!
        
        if NSJSONSerialization.isValidJSONObject(packetNSString) {
            do {
                _ = try NSJSONSerialization.dataWithJSONObject(packetNSString, options: NSJSONWritingOptions(rawValue: 0))
            } catch {
                exit(1)
            }
        }
        
        return packetNSString.dataUsingEncoding(NSUTF8StringEncoding)!
    }
    
    
    // Image Structures and functions
    enum imgFlags : UInt32 {
        case SHA256                 = 0x00000002    // Image contains hash TLV
        case PKCS15_RSA2048_SHA256  = 0x00000004    // PKCS15 w/RSA and SHA
        case ECDSA224_SHA256        = 0x00000008    // ECDSA256 over SHA256
        
        var code:UInt32 {
            return rawValue
        }
    }
    
    let IMAGE_HEADER_SIZE:UInt16    = 32
    let IMAGE_MAGIC:UInt32          = 0x96f3b83c
    let IMAGE_MAGIC_NONE:UInt32     = 0xffffffff
    let IMGMGR_HASH_LEN:UInt32      = 32
    let IMAGE_TLV_SIZE:UInt32       = 4
    
    // Image trailer TLV types.
    
    enum imgTlvType : UInt8 {
        case SHA256   = 1 // SHA256 of image hdr and body
        case RSA2048  = 2 // RSA2048 of hash output
        case ECDSA224 = 3 // ECDSA of hash output
        
        var code:UInt8 {
            return rawValue
        }
    }
    
    struct imgVersion {
        var major: UInt8
        var minor: UInt8
        var revision: UInt16
        var buildNum: UInt32
        
        init () {
            self.major      = 0
            self.minor      = 0
            self.revision   = 0
            self.buildNum   = 0
        }
    }
    
    func nmgrImgSize(hdr: imgHeader) -> UInt32 {
        return UInt32(hdr.tlvSize) + UInt32(hdr.hdrSize) + UInt32(hdr.imgSize)
    }
    
    // Image header.  All fields are in little endian byte order.
    struct imgHeader {
        var magic:UInt32
        var tlvSize:UInt16  // Trailing TLVs
        var keyId:UInt8
        //uint8_t  _pad1;
        var hdrSize:UInt16
        //uint16_t _pad2;
        var imgSize:UInt32  // Does not include header.
        var flags:UInt32
        var ver: imgVersion
        //uint32_t _pad3;
        
        init?(magic:UInt32, tlvSize:UInt16,
              keyId:UInt8, hdrSize:UInt16,
              imgSize:UInt32, flags:UInt32,
              ver:imgVersion) {
            
            self.magic    = magic
            self.tlvSize  = tlvSize // Trailing TLVs
            self.keyId    = keyId
            //uint8_t  _pad1;
            self.hdrSize  = hdrSize
            //uint16_t _pad2;
            self.imgSize  = imgSize // Does not include header.
            self.flags     = flags
            self.ver = imgVersion()
        }
        
        func decode (imdata: NSData) -> imgHeader {
            var magic:UInt32    = 0
            var tlvSize:UInt16  = 0 // Trailing TLVs
            var keyId:UInt8     = 0
            //uint8_t  _pad1;
            var hdrSize:UInt16  = 0
            //uint16_t _pad2;
            var imgSize:UInt32  = 0 // Does not include header.
            var flags:UInt32    = 0
            var ver             = imgVersion()
            
            imdata.getBytes(&magic, range: NSRange(location: 0, length: 4))
            imdata.getBytes(&tlvSize, range: NSRange(location: 4, length: 2))
            imdata.getBytes(&keyId, range: NSRange(location: 6, length: 1))
            //uint8_t  _pad1
            imdata.getBytes(&hdrSize, range: NSRange(location: 8, length: 2))
            //uint16_t _pad2;
            imdata.getBytes(&imgSize, range: NSRange(location: 12, length: 4))
            imdata.getBytes(&flags, range: NSRange(location: 16, length: 4))
            imdata.getBytes(&ver.major, range: NSRange(location: 21, length: 1))
            imdata.getBytes(&ver.minor, range: NSRange(location: 22, length: 1))
            imdata.getBytes(&ver.revision, range: NSRange(location: 23, length: 2))
            imdata.getBytes(&ver.buildNum, range: NSRange(location: 25, length: 4))
            
            return imgHeader(magic:magic,
                             tlvSize:tlvSize,
                             keyId: keyId,
                             hdrSize: hdrSize,
                             imgSize:imgSize,
                             flags: flags,
                             ver: ver
                )!
        }
    }
    
    // Image trailer TLV format. All fields in little endian.
    struct imgTlv {
        var type: UInt8
        //uint8_t  _pad;
        var len: UInt16
        
        init?(type: UInt8, len: UInt16) {
            self.type = type
            self.len  = len
        }
        
        func decode (imdata: NSData) -> imgTlv {
            var type: UInt8 = 0
            //uint8_t  _pad;
            var len: UInt16 = 0
            
            imdata.getBytes(&type, range: NSRange(location: 0, length: 1))
            //uint8_t  _pad;
            imdata.getBytes(&len, range: NSRange(location: 2, length: 2))
            
            return imgTlv(type:type, len:len)!
        }
    }
    
    func createNmgrImgBoot2(img: DFUFirmware) -> NSData {
        var ver:imgVersion
        var buildId:NSData
        
        (ver,buildId) = imgrReadInfo(img)
        return createNmgrPacket(NmgrRequest.Activate.req, data: imgBoot2JSONEncode(buildId)).0
    }
        
    func imgrReadInfo(img: DFUFirmware) -> (imgVersion, NSData) {
        var hdr = imgHeader(magic: 0, tlvSize: 0, keyId: 0, hdrSize: 0, imgSize: 0, flags: 0, ver: imgVersion())
        var tlv = imgTlv(type: 0, len: 0)
        var data = img.data
        var ver = imgVersion()
        var hash = NSData()
    
        hdr = hdr!.decode(img.data)

        if hdr!.magic == IMAGE_MAGIC {
            ver = hdr!.ver
        } else if (hdr!.magic == 0xffffffff) {
            report?(error:DFUError.WritingCharacteristicFailed, withMessage:"rc:2 : Imgr: No magic set")
        } else {
            report?(error:DFUError.WritingCharacteristicFailed, withMessage:"rc:1 : Imgr: No magic set")
        }
    
        // Build ID is in a TLV after the image.

        var dataOff = UInt32(hdr!.hdrSize) + UInt32(hdr!.imgSize)
        var dataEnd = dataOff + UInt32(hdr!.tlvSize)
        
        while (dataOff + IMAGE_TLV_SIZE  <= dataEnd) {
            tlv = tlv!.decode(img.data.subdataWithRange(NSRange(location: Int(dataOff), length:Int(IMAGE_TLV_SIZE))))
            if (tlv!.type == 0xff && tlv!.len == 0xffff) {
                break;
            }
            
            if (tlv!.type != imgTlvType.SHA256.code || UInt32(tlv!.len) != IMGMGR_HASH_LEN) {
                dataOff += IMAGE_TLV_SIZE + UInt32(tlv!.len)
                continue
            }
            dataOff += IMAGE_TLV_SIZE
            if (dataOff + IMGMGR_HASH_LEN > dataEnd) {
                return (ver, NSData())
            }
            
            hash = img.data.subdataWithRange(NSRange(location: Int(dataOff), length:Int(IMGMGR_HASH_LEN)))
        }
        
        return (ver, hash)
    }

    func createNmgrReset() -> NSData {
        
        return createNmgrPacket(NmgrRequest.Reset.req, data: resetJSONEncode()).0
    }
    
    func createNmgrImgBoot(img: NSData) -> NSData {
    
        return createNmgrPacket(NmgrRequest.Activate.req, data: imgBootJSONEncode(img)).0
    }
    
    func createNmgrPacket(var request: nmgrPacket, data: NSData) -> (NSData, UInt16) {
        
        NSLog("Nmgr Reuest Payload \(data)")
        request.Len = UInt16(data.length)
        
        return (request.encode(data), request.Len)
    }
    
    func send(request:NmgrRequest, firmware: DFUFirmware, onSuccess success:NmgrServiceCallback?, onError report:NmgrServiceErrorCallback?) {
        var writedata:NSData
        var nmgrDataLen:UInt16
        
        // Save callbacks and parameter
        self.success = success
        self.report = report
        self.Request = request
        self.resetSent = false
        
        // Get the peripheral object
        let peripheral = characteristic.service.peripheral
        
        // Set the peripheral delegate to self
        peripheral.delegate = self
        
        switch Request! {
        case .Reset:
            self.resetSent = true
            writedata = createNmgrReset()
            break
        case .Activate:
            writedata = createNmgrImgBoot2(firmware)
        case .Upload:
            (writedata,nmgrDataLen) = createNmgrDFUPacket(firmware.data)
            if writedata.length == 0 {
                success?()
                return
            }
            break
        default:
            break
        }
        
        logger.v("Writing to characteristic \(NmgrDfuChr.UUID.UUIDString)...")
        logger.d("peripheral.writeValue(0x\(writedata), forCharacteristic: \(NmgrDfuChr.UUID.UUIDString), type: WithoutResponse)")
        peripheral.writeValue(writedata, forCharacteristic: characteristic, type: CBCharacteristicWriteType.WithoutResponse)
    }
    
    /**
     Sends next number of packets from given firmware data and reports a progress.
     This method does not notify progress delegate twice about the same percentage.
     
     - parameter number:           number of packets to be sent before a Packet Receipt Notification is expected.
     Set to 0 to disable Packet Receipt Notification procedure (not recommended)
     - parameter firmware:         the firmware to be sent
     - parameter progressDelegate: an optional progress delegate
     */
    func sendNext(number:UInt16, packetsOf firmware:DFUFirmware, andReportProgressTo progressDelegate:DFUProgressDelegate?) {
        // Get the peripheral object
        let peripheral = characteristic.service.peripheral
        
        // Some super complicated computations...
        let bytesTotal = firmware.data.length
        let totalPackets = (bytesTotal + PacketSize - 1) / PacketSize
        let packetsSent  = (offset + PacketSize - 1) / PacketSize
        let packetsLeft = totalPackets - packetsSent
        
        let bytesLeft = bytesTotal - offset
        var packet:NSData
        var packetLength:UInt16
        
        (packet, packetLength) = createNmgrDFUPacket(firmware.data)
        
        if packet.length == 0 {
            return
        }
        
        logger.v("Send Next:: Writing to characteristic \(NmgrDfuChr.UUID.UUIDString)...")
        logger.d("peripheral.writeValue(0x\(packet.hexString), forCharacteristic: \(NmgrDfuChr.UUID.UUIDString), type: WithoutResponse)")
        peripheral.writeValue(packet, forCharacteristic: characteristic, type: CBCharacteristicWriteType.WithoutResponse)
        
        // Calculate current transfer speed in bytes per second
        let now = CFAbsoluteTimeGetCurrent()
        let currentSpeed = Double(packetLength) / (now - lastTime!)
        lastTime = now
        
        // Calculate progress
        let currentProgress = (offset * 100 / bytesTotal) // in percantage (0-100)
        
        // Notify progress listener
        if currentProgress > progress {
            let avgSpeed = Double(offset) / (now - startTime!)
            
            dispatch_async(dispatch_get_main_queue(), {
                progressDelegate?.onUploadProgress(
                    firmware.currentPart,
                    totalParts: firmware.parts,
                    progress: currentProgress,
                    currentSpeedBytesPerSecond: currentSpeed,
                    avgSpeedBytesPerSecond: avgSpeed)
            })
            progress = currentProgress
        }
    }
    
    /**
     Enables notifications for the Nmgr characteristics. Reports success or an error
     using callbacks.
     
     - parameter success: method called when notifications were successfully enabled
     - parameter report:  method called in case of an error
     */
    func enableNotifications(onSuccess success:NmgrServiceCallback?, onError report:NmgrServiceErrorCallback?) {
        // Save callbacks
        self.success = success
        self.report = report
        
        // Get the peripheral object
        let peripheral = characteristic.service.peripheral
        peripheral.delegate = self
        
        logger.v("Nmgr: Enabling notifications for \(characteristic.UUID.UUIDString)...")
        logger.d("peripheral.setNotifyValue(true, forCharacteristic: \(characteristic.UUID.UUIDString))")
        peripheral.setNotifyValue(true, forCharacteristic: characteristic)
    }
    
    func waitUntilUploadComplete(onSuccess success:Callback?, onNmgrResponseNofitication proceed:ProgressCallback?, onError report:ErrorCallback?) {
        // Save callbacks. The proceed callback will be called periodically whenever a nmgr response is received. It resumes uploading.
        self.success = success
        self.proceed = proceed
        self.report = report
        self.uploadStartTime = CFAbsoluteTimeGetCurrent()
        
        // Get the peripheral object
        let peripheral = characteristic.service.peripheral
        // Set the peripheral delegate to self
        peripheral.delegate = self
        
        logger.a("Uploading firmware...")
    }
    
    // Peripheral Delegate callbacks
    
    func peripheral(peripheral: CBPeripheral, didUpdateNotificationStateForCharacteristic characteristic: CBCharacteristic, error: NSError?) {
        if error != nil {
            logger.e("Enabling notifications failed")
            logger.e(error!)
            report?(error:DFUError.EnablingControlPointFailed, withMessage:"Enabling notifications failed")
        } else {
            logger.v("Notifications enabled for \(NmgrDfuChr.UUID.UUIDString)")
            logger.a("Nmgr DFU notifications enabled")
            success?()
        }
    }
    
    func peripheral(peripheral: CBPeripheral, didWriteValueForCharacteristic characteristic: CBCharacteristic, error: NSError?) {
        if error != nil {
            if !self.resetSent {
                logger.e("Writing to characteristic failed")
                logger.e(error!)
                report?(error:DFUError.WritingCharacteristicFailed, withMessage:"Writing to characteristic failed")
            } else {
                // When a 'Activate' or 'Reset' command is sent the device may reset before sending the acknowledgement.
                // This is not a blocker, as the device did disconnect and reset successfully.
                logger.a("\(Request!.description) request sent")
                logger.w("Device disconnected before sending ACK")
                logger.w(error!)
                success?()
            }
        } else {
            logger.i("Data written to \(NmgrDfuChr.UUID.UUIDString)")
            switch Request! {
            case .Upload, .Activate, .Reset:
                logger.a("\(Request!.description) request sent")
            // do not call success until we get a notification

            }
        }
    }
    
    func peripheral(peripheral: CBPeripheral, didUpdateValueForCharacteristic characteristic: CBCharacteristic, error: NSError?) {
        if error != nil {
            // This characteristic is never read, the error may only pop up when notification is received
            logger.e("Receiving notification failed")
            logger.e(error!)
            report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Receiving notification failed")
        } else {
            
            logger.i("Notification received from \(NmgrDfuChr.UUID.UUIDString), value (0x):\(characteristic.value!.hexString)")
            // Parse response received
            let response = NmgrResponse(characteristic.value!)
            if let response = response {
                parseNmgrResponse(response)
            }
        }
    }
    
    func parseNmgrResponse(response: NmgrResponse) {
        
        var str = String(data: response.nmgrRsp.data, encoding: NSUTF8StringEncoding)
        NSLog("Nmgr Response Payload:\(str)")
        
        switch (response.nmgrRsp.Group, response.nmgrRsp.Id) {
        case (NmgrGrp.Image, OpDfu.Upload.code):
            parseImgUploadJSON(response)
            break
            
        case (NmgrGrp.Image, OpDfu.Boot.code):
            parseImgBootJSON(response)
            break
            
        case (NmgrGrp.Image, OpDfu.Boot2.code):
            parseImgBoot2JSON(response)
            break
            
        case (NmgrGrp.Image, OpDfu.List.code):
            //parseImgListJSON(response)
            break
        
        case (NmgrGrp.Image, OpDfu.List2.code):
            //parseImgListJSON(response)
            break
            
        case (NmgrGrp.Default, DefGrp.Reset.code):
            parseResetJSON(response)
            break
            
        default:
            report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Nmgr Error: Wrong Nmgr Grp and Id ")
            break
        }
    }
    
    func parseImgUploadJSON(response: NmgrResponse) {
        
        do {
            
            var json:[String:AnyObject] = try NSJSONSerialization.JSONObjectWithData(response.nmgrRsp.data, options: NSJSONReadingOptions.MutableContainers) as! [String:AnyObject]
            
            if let returnCode = (json["rc"] as? NSNumber)?.unsignedShortValue {
                if returnCode == ReturnCode.EOk.code {
                    if let  off = (json["off"] as? NSNumber)?.integerValue {
                        offset = off
                        if proceed != nil {
                            self.proceed?(bytesReceived: self.offset)
                        }
                        success?()
                    }
                } else {
                    report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Nmgr Error: \(ReturnCode(rawValue: UInt16(returnCode))?.description)")
                }
            } else {
                report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Notification failed: JSON decoding failed")
            }
        } catch {
            report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Notification failed: JSON decoding failed")
        }
    }
    
    func parseImgBootJSON(response: NmgrResponse) {
        
        do {
            
            var json:[String:AnyObject] = try NSJSONSerialization.JSONObjectWithData(response.nmgrRsp.data, options: NSJSONReadingOptions.MutableContainers) as! [String:AnyObject]
            
            if let returnCode = (json["rc"] as? NSNumber)?.unsignedShortValue {
                if returnCode != ReturnCode.EOk.code {
                    report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Nmgr Error: \(ReturnCode(rawValue: UInt16(returnCode))?.description)")
                } else {
                    success?()
                }
            } else {
                report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Notification failed: JSON decoding failed")
            }
        } catch {
            report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Notification failed: JSON decoding failed")
        }
    }
    
    func parseImgBoot2JSON(response: NmgrResponse) {
        
        do {
            
            var json:[String:AnyObject] = try NSJSONSerialization.JSONObjectWithData(response.nmgrRsp.data, options: NSJSONReadingOptions.MutableContainers) as! [String:AnyObject]
            
            if let returnCode = (json["rc"] as? NSNumber)?.unsignedShortValue {
                if returnCode != ReturnCode.EOk.code {
                    report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Nmgr Error: \(ReturnCode(rawValue: UInt16(returnCode))?.description)")
                } else {
                    success?()
                }
            } else {
                report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Notification failed: JSON decoding failed")
            }
        } catch {
            report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Notification failed: JSON decoding failed")
        }
    }
    
    func parseResetJSON(response: NmgrResponse) {
        
        do {
            
            var json:[String:AnyObject] = try NSJSONSerialization.JSONObjectWithData(response.nmgrRsp.data, options: NSJSONReadingOptions.MutableContainers) as! [String:AnyObject]
            
            if let returnCode = (json["rc"] as? NSNumber)?.unsignedShortValue {
                if returnCode != ReturnCode.EOk.code {
                    report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Nmgr Error: \(ReturnCode(rawValue: UInt16(returnCode))?.description)")
                } else {
                    success?()
                }
            } else {
                report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Notification failed: JSON decoding failed")
            }
        } catch {
            report?(error:DFUError.ReceivingNotificatinoFailed, withMessage:"Notification failed: JSON decoding failed")
        }
    }
}