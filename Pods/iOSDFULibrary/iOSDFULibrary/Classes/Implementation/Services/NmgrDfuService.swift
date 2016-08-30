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

internal typealias NmgrServiceCallback = Void -> Void
internal typealias NmgrServiceErrorCallback = (error:DFUError, withMessage:String) -> Void

@objc internal class NmgrDfuService : NSObject, CBPeripheralDelegate {
    
    static internal let UUID = CBUUID.init(string: "8D53DC1D-1DB7-4CD3-868B-8A527460AA84")
    
    static func matches(service:CBService) -> Bool {
        return service.UUID.isEqual(UUID)
    }
    /// The target DFU Peripheral
    var targetPeripheral : DFUPeripheral?
    
    /// The logger helper.
    private var logger:LoggerHelper
    /// The service object from CoreBluetooth used to initialize the DFUService instance.
    private let service:CBService
    private var nmgrDfuCharacteristic:NmgrDfuChr?
    
    /// The version read from the DFU Version charactertistic. Nil, if such does not exist.
    private(set) var version:(major:Int, minor:Int)?
    private var paused = false
    private var aborted = false
    
    /// A temporary callback used to report end of an operation.
    private var success:NmgrServiceCallback?
    /// A temporary callback used to report an operation error.
    private var report:NmgrServiceErrorCallback?
    /// A temporaty callback used to report progress status.
    private var progressDelegate:DFUProgressDelegate?
    
    // -- Properties stored when upload started in order to resume it --
    private var firmware:DFUFirmware?
    private var packetReceiptNotificationNumber:UInt16?
    // -- End --
    
    // Initialization
    
    init(_ service:CBService, _ logger:LoggerHelper) {
        self.service = service
        self.logger = logger
        super.init()
    }
    
    // Service API methods
    
    /**
     Discovers characteristics in the DFU Service. This method also reads the DFU Version characteristic if such found.
     */
    func discoverCharacteristics(onSuccess success: NmgrServiceCallback, onError report:NmgrServiceErrorCallback) {
        // Save NmgrServiceCallbacks
        self.success = success
        self.report = report
        
        // Get the peripheral object
        let peripheral = service.peripheral
        
        // Set the peripheral delegate to self
        peripheral.delegate = self
        
        // Discover DFU characteristics
        logger.v("Discovering characteristics in Nmgr DFU Service...")
        logger.d("peripheral.discoverCharacteristics(nil, forService:NmgrDFUService)")
        peripheral.discoverCharacteristics(nil, forService:service)
    }
    
    /**
     This method tries to estimate whether the DFU target device is in Application mode
     
     - returns: true, if it is for sure in the Application more, false, if definitely is not, nil if uknown
     */
    func isInApplicationMode() -> Bool? {
        
        return false
    }
    
    /**
     This method sends the Init Packet with additional firmware metadata to the target DFU device.
     The Init Packet is required since Bootloader v0.5 (SDK 7.0.0), when it has been extended with
     firmware verification data, like IDs of supported softdevices, device type and revision, or application version.
     The extended Init Packet may also contain a hash of the firmware (since DFU from SDK 9.0.0).
     Before Init Packet became required it could have contained only 2-byte CRC of the firmware.
     
     - parameter data:    the Init Packet data
     - parameter success: a NmgrServiceCallback called when a response with status Success is received
     - parameter report:  a NmgrServiceCallback called when a response with an error status is received
     */
    func sendInitPacket(data:NSData, onSuccess success: NmgrServiceCallback, onError report:NmgrServiceErrorCallback) {
        if aborted {
            sendReset(onError: report)
            return
        }

        if data.length < 32 {
            // Init packet validation would have failed. We can safely abort here.
            report(error: DFUError.ExtendedInitPacketRequired, withMessage: "Nmgr header might not be present in Init Packet")
            return
        }
        
        if firmware != nil {
            
            sendFirmware(firmware!, withPacketReceiptNotificationNumber: 1,
                         onProgress: progressDelegate,
                         onSuccess:success,
                         onError: {
                                    error, message in if error == DFUError.RemoteOperationFailed {
                                        report(error: error, withMessage: "Operation failed")
                                    } else {
                                        report(error: error, withMessage: message)
                                    }
                }
            )
        } else {
            success()
        }
    }
    
    /**
     Sends the firmware data to the DFU target device.
     
     - parameter firmware: the firmware to be sent
     - parameter number:   number of packets of firmware data to be received by the DFU target before
     sending a new Packet Receipt Notification
     - parameter progressDelegate: a progress delagate that will be informed about transfer progress
     - parameter success:  a NmgrServiceCallback called when a response with status Success is received
     - parameter report:   a NmgrServiceCallback called when a response with an error status is received
     */
    func sendFirmware(firmware:DFUFirmware, withPacketReceiptNotificationNumber number:UInt16,
                      onProgress progressDelegate:DFUProgressDelegate?, onSuccess success: NmgrServiceCallback, onError report:NmgrServiceErrorCallback) {
        if aborted {
            sendReset(onError: report)
            return
        }
        
        // Store parameters in case the upload was paused and resumed
        self.firmware = firmware
        self.packetReceiptNotificationNumber = number
        self.progressDelegate = progressDelegate
        self.report = report
        
        // 1. Sends the Firmware Image Upload command with firmware to the Nmgr characteristic
        // 2. Sends firmware to the Nmgr characteristic. If number > 0 it will receive Packet Receipt Notifications
        //    every number packets.
        // 3. Receives response notification and calls onSuccess or onError
        
        nmgrDfuCharacteristic!.send(NmgrDfuChr.NmgrRequest.Upload, firmware: firmware,
            onSuccess: {
                // Register NmgrServiceCallbacks for Nmgr Responses
                self.nmgrDfuCharacteristic!.waitUntilUploadComplete(
                    onSuccess: {
                        if self.nmgrDfuCharacteristic!.offset >= self.firmware?.data.length {
                            success()
                        }
                        // Upload is completed, release the temporary parameters
                    },
                    onNmgrResponseNofitication: {
                        bytesReceived in
                        // Each time a valid response is received, send the next packet
                        if !self.paused && !self.aborted {
                            let bytesSent = self.nmgrDfuCharacteristic!.offset
                            if bytesSent == bytesReceived {
                                self.nmgrDfuCharacteristic!.sendNext(number, packetsOf: firmware, andReportProgressTo: progressDelegate)
                            } else {
                                // Target device reported invalid number of bytes received
                                report(error:DFUError.BytesLost, withMessage: "\(bytesSent) bytes were sent while \(bytesReceived) bytes were reported as received")
                            }
                        } else if self.aborted {
                            // Upload has been aborted. Reset the target device. It will disconnect automatically
                            self.sendReset(onError: report)
                        }
                    },
                    onError: {
                        error, message in
                        // Upload failed, release the temporary parameters
                        self.firmware = nil
                        self.packetReceiptNotificationNumber = nil
                        self.progressDelegate = nil
                        self.report = nil
                        report(error: error, withMessage: message)
                    }
                )
                // ...and start sending firmware
                if !self.paused && !self.aborted {
                    self.nmgrDfuCharacteristic!.sendNext(number, packetsOf: firmware, andReportProgressTo: progressDelegate)
                } else if self.aborted {
                    // Upload has been aborted. Reset the target device. It will disconnect automatically
                    self.sendReset(onError: report)
                }
            },
            onError: report
        )
    }
    
    func pause() {
        if !aborted {
            paused = true
        }
    }
    
    func resume() {
        if !aborted && paused && firmware != nil {
            paused = false
            // onSuccess and onError NmgrServiceCallbacks are still kept by dfuControlPointCharacteristic
            nmgrDfuCharacteristic!.sendNext(packetReceiptNotificationNumber!, packetsOf: firmware!, andReportProgressTo: progressDelegate)
        }
        paused = false
    }
    
    func abort() {
        aborted = true
        // When upload has been started and paused, we have to send the Reset command here as the device will
        // not get a Packet Receipt Notification. If it hasn't been paused, the Reset command will be sent after receiving it, on line 270.
        if paused && firmware != nil {
            // Upload has been aborted. Reset the target device. It will disconnect automatically
            sendReset(onError: report!)
        }
        paused = false
    }
    
    /**
     Enables notifications for Nmgr DFU characteristic. Result it reported using callbacks.
     
     - parameter success: method called when notifications were enabled without a problem
     - parameter report:  method called when an error occurred
     */
    func enableControlPoint(onSuccess success: NmgrServiceCallback, onError report:NmgrServiceErrorCallback) {
        if !aborted {
            nmgrDfuCharacteristic!.enableNotifications(onSuccess: success, onError: report)
        } else {
            sendReset(onError: report)
        }
    }
    
    /**
     Sends a command that will activate the new firmware and reset the DFU target device.
     Soon after calling this method the device should disconnect.
     
     - parameter report: a NmgrServiceCallback called when writing characteristic failed
     */
    func sendActivateAndResetRequest(onError report:NmgrServiceErrorCallback) {
        if !aborted {
            if firmware != nil {
                nmgrDfuCharacteristic!.send(NmgrDfuChr.NmgrRequest.Activate, firmware: firmware!,
                                            onSuccess: { () -> () in self.nmgrDfuCharacteristic!.send(NmgrDfuChr.NmgrRequest.Reset,
                                                         firmware: self.firmware!,
                                                         onSuccess: nil,
                                                         onError: report) },
                                            onError: report)
            }
        } else {
            sendReset(onError: report)
        }
    }
    
    /**
     Sends a Reset command to the target DFU device. The device will disconnect automatically and restore the
     previous application (if DFU dual bank was used and application wasn't removed to make space for a new
     softdevice) or bootloader.
     
     - parameter report: a NmgrServiceCallback called when writing characteristic failed
     */
    private func sendReset(onError report:NmgrServiceErrorCallback) {
        nmgrDfuCharacteristic!.send(NmgrDfuChr.NmgrRequest.Reset, firmware: firmware!, onSuccess: nil, onError: report)
    }
    
    // Peripheral Delegate NmgrServiceCallbacks
    
    func peripheral(peripheral: CBPeripheral, didDiscoverCharacteristicsForService service: CBService, error: NSError?) {
        // Create local references to NmgrServiceCallback to release the global ones
        let _success = self.success
        let _report = self.report
        self.success = nil
        self.report = nil
        
        if error != nil {
            logger.e("Characteristics discovery failed")
            logger.e(error!)
            _report?(error: DFUError.ServiceDiscoveryFailed, withMessage: "Characteristics discovery failed")
        } else {
            logger.i("DFU characteristics discovered")
            
            // Find DFU characteristics
            for characteristic in service.characteristics! {
                if (NmgrDfuChr.matches(characteristic)) {
                    nmgrDfuCharacteristic = NmgrDfuChr(characteristic, logger)
                }
            }
            
            // Some validation
            if nmgrDfuCharacteristic == nil {
                logger.e("Nmgr DFU characteristic not found")
                // DFU Control Point characteristic is required
                _report?(error: DFUError.DeviceNotSupported, withMessage: "DFU Control Point characteristic not found")
                return
            }
            if !nmgrDfuCharacteristic!.valid {
                logger.e("Nmgr DFU characteristic must have Write and Notify properties")
                // DFU Control Point characteristic must have Write and Notify properties
                _report?(error: DFUError.DeviceNotSupported, withMessage: "Nmgr DFU characteristic does not have the Write and Notify properties")
                return
            }
            
            // Note: DFU Packet characteristic is not required in the App mode.
            //       The mbed implementation of DFU Service doesn't have such.
            
            // Read DFU Version characteristic if such exists
            if nmgrDfuCharacteristic != nil {
                if nmgrDfuCharacteristic!.read_valid {
                    //readDfuVersion(onSuccess: _success!, onError: _report!)
                } else {
                    version = nil
                    logger.i("DFU Characteristic found, but does not have the Read property")
                    _success?()
                }
            } else {
                // Else... proceed
                version = nil
                _success?()
            }
        }
    }
}