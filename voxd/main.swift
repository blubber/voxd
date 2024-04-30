import Foundation
import AVFoundation
import FlyingFox

struct VoiceSettings: Decodable {
    var pitch: Float = 1.0
    var rate: Float = 1.0
    var volume: Float = 1.0
    var voice: String = "Samantha"
    
    private enum CodingKeys: String, CodingKey {
        case pitch, rate, volume, voice
    }
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pitch = (try? container.decode(Float.self, forKey: .pitch)) ?? 1.0
        rate = (try? container.decode(Float.self, forKey: .rate)) ?? 1.0
        volume = (try? container.decode(Float.self, forKey: .volume)) ?? 1.0
        voice = (try? container.decode(String.self, forKey: .voice)) ?? "Samantha"
    }
}

struct Settings: Decodable {
    var port: UInt16 = 1729
    let voices: [String: VoiceSettings]
    

    private enum CodingKeys: String, CodingKey {
        case port, voices
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = (try? container.decode(UInt16.self, forKey: .port)) ?? 1729
        voices = (try? container.decodeIfPresent([String: VoiceSettings].self, forKey: .voices)) ?? [:]
    }
}

struct Utterance: Decodable {
    let voice: String
    let text: String
}


struct Voice {
    let pitch: Float
    let rate: Float
    let volume: Float
    let voice: AVSpeechSynthesisVoice?
}


class SpeechManager: NSObject {
    private let voices: [String: Voice]
    private var queue = [AVSpeechUtterance]()
    private let synth = AVSpeechSynthesizer()
    
    
    init(voices: [String: Voice]) {
        self.voices = voices
        super.init()
        synth.delegate = self
    }
    
    func stopSpeaking() {
        queue.removeAll()
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }
    
    func schedule(_ utterances: [Utterance]) {
        stopSpeaking()
        
        queue = utterances.compactMap { utterance in
            var voice: Voice = voices["__default"]!
            if let selectedVoice = voices[utterance.voice] {
                voice = selectedVoice
            }
            
            let avSpeechUtterance = AVSpeechUtterance(string: utterance.text)
            avSpeechUtterance.pitchMultiplier = voice.pitch
            avSpeechUtterance.rate = voice.rate / 2
            avSpeechUtterance.volume = voice.volume
            avSpeechUtterance.voice = voice.voice
            
            return avSpeechUtterance
        }
        
        scheduleNext()
    }
    
    func scheduleNext() {
        if let utterance = queue.last {
            synth.speak(utterance)
        }
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synth: AVSpeechSynthesizer, didFinish: AVSpeechUtterance) {
        if let last = queue.last {
            if last === didFinish {
                queue.removeLast()
                scheduleNext()
            }
        }
    }

}


func readSettings() -> Settings {
    let filePath = String(NSString(string: "~/.config/voxd.json").expandingTildeInPath)
    let data = try! Data(contentsOf: URL(fileURLWithPath: filePath))
    return try! JSONDecoder().decode(Settings.self, from: data)
}


func listVoices(_ languages: [String]) {
    let languages = languages.map { $0.lowercased() }
    
    print("Name            Quality  Language")
    
    for voice in AVSpeechSynthesisVoice.speechVoices() {
        if languages.isEmpty || languages.contains(voice.language.lowercased()) {
            let quality = switch(voice.quality) {
            case .default: "default "
            case .premium: "premium "
            case .enhanced: "enhanced"
            default: "higher"
            }
            
            print("\(voice.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(quality) \(voice.language)")
        }
    }
}


func resolveVoice(_ voiceName: String) -> AVSpeechSynthesisVoice? {
    let voiceName = voiceName.lowercased()
    for voice in AVSpeechSynthesisVoice.speechVoices() {
        if voice.name.lowercased() == voiceName {
            return voice
        }
    }
    
    return nil
}

func serve(_ settings: Settings) async {
    var voices = [String: Voice]()
    for (voiceId, voiceSettings) in settings.voices {
        let avSpeechVoice = resolveVoice(voiceSettings.voice)
        
        voices[voiceId] = Voice(
            pitch: voiceSettings.pitch,
            rate: voiceSettings.rate,
            volume: voiceSettings.volume,
            voice: avSpeechVoice
        )
    }
    voices["__default"] = Voice(pitch: 1.0, rate: 1.0, volume: 1.0, voice: nil)
    
    let speechManager = SpeechManager(voices: voices)
    let jsonDecoder = JSONDecoder()
    
    let server = try! HTTPServer(address: .inet(ip4: "127.0.0.1", port: settings.port))
    
    await server.appendRoute(HTTPRoute("POST /speak", headers: [.contentType: "application/json"])) { request in
        guard let bodyData = try? await request.bodyData else {
            return HTTPResponse(statusCode: .unprocessableContent)
        }
        if bodyData.isEmpty {
            return HTTPResponse(statusCode: .unprocessableContent)
        }
    
        if let utterances = try? jsonDecoder.decode([Utterance].self, from: bodyData) {
            speechManager.schedule(utterances)
            return HTTPResponse(statusCode: .accepted)
        }
    
        return HTTPResponse(statusCode: .unprocessableContent)
    
    }
    
    
    signal(SIGINT, SIG_IGN) // // Make sure the signal does not terminate the application.
    let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSrc.setEventHandler {
        exit(0)
    }
    sigintSrc.resume()
    try! await server.start()
}


if CommandLine.arguments.count > 1 {
    switch(CommandLine.arguments[1]) {
    case "voices":
        let languages = CommandLine.arguments[2...]
        listVoices(Array(languages))
        
    case "serve":
        let settings = readSettings()
        await serve(settings)
    
    default:
        print("ERROR: Invalid command, valid commands are voices and serve (default)")
        exit(-1)
    }
} else {
    let settings = readSettings()
    await serve(settings)
}


