//
//  ViewController.swift
//  SAM
//
//  Created by Eric Lam
//  Copyright © 2017 VOIQ.
//

import UIKit
import Speech
import ApiAI
import AVFoundation
import SwiftSiriWaveformView
import Accelerate

class ViewController: UIViewController, AVSpeechSynthesizerDelegate, SFSpeechRecognizerDelegate {
	
	@IBOutlet weak var textView: UITextView!
	@IBOutlet weak var microphoneButton: UIButton!
	
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.init(identifier: "en-US"))!
    
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    //Text to Speech
    private let synthetizer = AVSpeechSynthesizer()
    private var myUtterance = AVSpeechUtterance(string: "")
    private let lang = "en-GB"
    
    //Animate
    private var timer:Timer?
    private var change:CGFloat = 0.01
    private var waveAmplitude:CGFloat = 0.03
    @IBOutlet weak var audioView: SwiftSiriWaveformView!
    //Animate
    
    //Pause Counter
    private var detectingPauseTimer:Timer?
    var secondsElapsed = 0
    
    //Signal Processing
    let LEVEL_LOWPASS_TRIG:Float32 = 0.01
    let averagePowerForChannel0:Float32 = -0.2
    var maxPower:Float32 = -0.44
    var minPower:Float32 = -0.64
    var samplesNumber:Int = 0
    
	override func viewDidLoad() {
        super.viewDidLoad()
        
        //Animate
        self.audioView.density = 1.0
        createTimerAnimation(amplitude: 0.05, interval: 0.05)
        
        //Settings and delegates
        microphoneButton.isEnabled = false
        
        speechRecognizer.delegate = self
        
        synthetizer.delegate = self
        
        
        SFSpeechRecognizer.requestAuthorization { (authStatus) in
            
            var isButtonEnabled = false
            
            switch authStatus {
            case .authorized:
                isButtonEnabled = true
                
            case .denied:
                isButtonEnabled = false
                print("User denied access to speech recognition")
                
            case .restricted:
                isButtonEnabled = false
                print("Speech recognition restricted on this device")
                
            case .notDetermined:
                isButtonEnabled = false
                print("Speech recognition not yet authorized")
            }
            
            OperationQueue.main.addOperation() {
                self.microphoneButton.isEnabled = isButtonEnabled
            }
        }
	}

	@IBAction func microphoneTapped(_ sender: AnyObject) {
        if audioEngine.isRunning {
            stopRecording()
        } else {
            startRecording()
        }
	}
    
    func stopRecording() {
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
        audioEngine.stop()
        let inputNode = audioEngine.inputNode
        inputNode?.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        microphoneButton.isEnabled = false
        microphoneButton.setTitle("Start Recording", for: .normal)
        microphoneButton.setTitleColor(UIColor(red:0.01, green:0.48, blue:1.00, alpha:1.0), for: .normal)
        //microphoneButton.setImage(UIImage(named: "mic"), for: .normal)
    }

    func startRecording() {
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
        
        microphoneButton.setTitle("Stop Recording", for: .normal)
        microphoneButton.setTitleColor(UIColor.red, for: .normal)
        
        if recognitionTask != nil {  //1
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        self.createTimerAnimation(amplitude: 0.3, interval: 0.03)
        self.audioView.waveColor = UIColor(red:0.29, green:0.92, blue:0.92, alpha:1.0)
        
        let audioSession = AVAudioSession.sharedInstance()  //2
        do {
            //try audioSession.setCategory(AVAudioSessionCategoryRecord)
            try audioSession.setCategory(AVAudioSessionCategoryPlayAndRecord, with: AVAudioSessionCategoryOptions.defaultToSpeaker)
            try audioSession.setMode(AVAudioSessionModeMeasurement)
            try audioSession.setActive(true, with: .notifyOthersOnDeactivation)
        } catch {
            print("audioSession properties weren't set because of an error.")
        }
        
        //print(audioSession.AVAudioSessionDataSourceDescription)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()  //3
        
        guard let inputNode = audioEngine.inputNode else {
            fatalError("Audio engine has no input node")
        }  //4
        
        guard let recognitionRequest = recognitionRequest else {
            fatalError("Unable to create an SFSpeechAudioBufferRecognitionRequest object")
        } //5
        
        recognitionRequest.shouldReportPartialResults = true  //6
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest, resultHandler: {
            (result, error) in  //7

            var isFinal = false  //8
            
            if result != nil {
                let bestTranscription = result?.bestTranscription.formattedString
                //self.startDetectingPause()
                self.textView.text = bestTranscription //9
                isFinal = (result?.isFinal)!
                if isFinal {
                    self.sendText(intent: bestTranscription)
                }
            }
            
            if error != nil || isFinal {  //10
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                
                self.recognitionRequest = nil
                self.recognitionTask = nil
                
                self.microphoneButton.isEnabled = true
            }
        })
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)  //11
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            self.recognitionRequest?.append(buffer)
            
            let inNumberFrames:UInt32 = buffer.frameLength
            //var samples:Float32 = buffer.floatChannelData![0][0]
            var avgValue:Float32 = 0
            vDSP_maxmgv((buffer.floatChannelData?[0])!, 1, &avgValue, vDSP_Length(inNumberFrames))
            
            let avg3:Float32 = ((avgValue == 0) ? (0-100) : 20.0)
        
            let averagePower = Float32(self.LEVEL_LOWPASS_TRIG) * Float32(avg3) * log10f(avgValue) + ((1-self.LEVEL_LOWPASS_TRIG) * (self.averagePowerForChannel0))

            //-0.5 is AvgPwrValue when user is silent
            let dB = 0.05 + averagePower
            
            if dB < self.minPower {
                self.minPower = dB
            }
            
            if dB > self.maxPower {
                self.maxPower = dB
            }
            
            let normalizedPower = (dB - self.minPower)/(self.maxPower - self.minPower)
            
            if normalizedPower < 0.2 {
                //self.audioView.amplitude = 0.05
                self.samplesNumber = self.samplesNumber + 1
            } else {
                //self.audioView.amplitude = 1.0
                self.samplesNumber = 0
            }
            
            /*if self.samplesNumber == 30 {
                /*DispatchQueue.main.async {
                    self.stopRecording()
                }*/
            }*/
            
            //print("AVG. POWER: " + String(normalizedPower))
            
        }
        
        audioEngine.prepare()  //12
        
        do {
            try audioEngine.start()
        } catch {
            print("audioEngine couldn't start because of an error.")
        }
        
        textView.text = "Say something, I'm listening!"
        
    }
    
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if available {
            microphoneButton.isEnabled = true
        } else {
            microphoneButton.isEnabled = false
        }
    }
    
    func startDetectingPause() {
        detectingPauseTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(self.checkPause), userInfo: nil, repeats: true);
    }
    
    func stopDetectingPause() {
        detectingPauseTimer?.invalidate()
    }
    
    func checkPause() {
        secondsElapsed = secondsElapsed + 1
        print(secondsElapsed)
        if secondsElapsed > 5{
            if audioEngine.isRunning {
                stopRecording()
                microphoneButton.isEnabled = false
                microphoneButton.setTitle("Start Recording", for: .normal)
            }
            secondsElapsed = 0
            stopDetectingPause()
        }
    }
    
    func sendText(intent: Optional<Any>) {
        
            let request = ApiAI.shared().textRequest()
        
            if let text = intent {
                request?.query = [text]
            } else {
                request?.query = [""]
            }
            
            request?.setMappedCompletionBlockSuccess({ (request, response) in
                let response = response as! AIResponse
                if response.result.action == "money" {
                    if let parameters = response.result.parameters as? [String: AIResponseParameter]{
                        let amount = parameters["amout"]!.stringValue
                        let currency = parameters["currency"]!.stringValue
                        let date = parameters["date"]!.dateValue
                        print("Spended \(amount) of \(currency) on \(date)")
                    }
                }
            }, failure: { (request, error) in
                // TODO: handle error
            })
        
        request?.setCompletionBlockSuccess({[unowned self] (request, response) -> Void in
            
            let response = response
            
            //print(response is String)
            
            if let dictionary = response as? [String: Any] {
                if let result = dictionary["result"] as? [String: Any] {
                    if let fulfillment = result["fulfillment"] as? [String: Any] {
                        self.textView.text = fulfillment["speech"] as! String!
                        self.textToSpeech(speech: fulfillment["speech"] as! String!)
                    }
                }
            }
            
            //self.present(resultNavigationController, animated: true, completion: nil)
                //hud.hide(animated: true)
            }, failure: { (request, error) -> Void in
                //hud.hide(animated: true)
        });
        
        ApiAI.shared().enqueue(request)
    }
    
    func textToSpeech(speech: String) {
        let str = speech
        //let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: str)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: self.lang)
        synthetizer.speak(utterance)
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        createTimerAnimation(amplitude: 1.0, interval: 0.009)
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        createTimerAnimation(amplitude: 0.05, interval: 0.05)
    }
    
    func createTimerAnimation(amplitude: CGFloat, interval: CGFloat) {
        timer?.invalidate()
        timer = nil
        self.waveAmplitude = CGFloat(amplitude)
        timer = Timer.scheduledTimer(timeInterval: TimeInterval(interval), target: self, selector: #selector(ViewController.startAIAnimation(_:)), userInfo: nil, repeats: true)
    }
    
    internal func startAIAnimation(_:Timer) {
        self.audioView.amplitude = self.waveAmplitude
    }

}

