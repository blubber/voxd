import Foundation
import AVFoundation
import FlyingFox

struct ChannelSettings: Decodable {
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
    var channels = [ChannelSettings()]
    

    private enum CodingKeys: String, CodingKey {
        case port, channels
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = (try? container.decode(UInt16.self, forKey: .port)) ?? 1729
        if let channels = try? container.decodeIfPresent([ChannelSettings].self, forKey: .channels) {
            self.channels = channels
        }
    }
}

struct Utterance: Decodable {
    let channel: Int
    let text: String
}


struct Channel {
    let pitch: Float
    let rate: Float
    let volume: Float
    let voice: AVSpeechSynthesisVoice
    let synth: AVSpeechSynthesizer
}


class SpeechManager: NSObject {
    private let channels: [Channel]
    private var queue = [(AVSpeechSynthesizer, AVSpeechUtterance)]()
    
    init(channels: [Channel]) {
        self.channels = channels
        
        super.init()
        
        for channel in channels {
            channel.synth.delegate = self
        }
    }
    
    func stopSpeaking() {
        self.queue = []
        for channel in channels {
            if channel.synth.isSpeaking {
                channel.synth.stopSpeaking(at: .immediate)
            }
        }
    }
    
    func schedule(_ utterances: [Utterance]) {
        stopSpeaking()
        
        let queue: [(AVSpeechSynthesizer, AVSpeechUtterance)] = utterances.compactMap { utterance in
            if utterance.channel < 0 || utterance.channel >= channels.count {
                return nil
            }
            
            let channel = channels[utterance.channel]
            let avSpeechUtterance = AVSpeechUtterance(string: utterance.text)
            
            avSpeechUtterance.pitchMultiplier = channel.pitch
            avSpeechUtterance.rate = channel.rate / 2
            avSpeechUtterance.volume = channel.volume
            avSpeechUtterance.voice = channel.voice
            
            return (channel.synth, avSpeechUtterance)
        }
        
        self.queue = queue.reversed()
        
        scheduleNext()
    }
    
    func scheduleNext() {
        if let (synth, utterance) = queue.last {
            synth.speak(utterance)
        }
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synth: AVSpeechSynthesizer, didFinish: AVSpeechUtterance) {
        if let (_, last) = queue.last {
            if last === didFinish {
                queue.removeLast()
                scheduleNext()
            }
        }
    }
    func speechSynthesizer(_ synth: AVSpeechSynthesizer, didCancel: AVSpeechUtterance) {
        print("CANCEL \(didCancel.speechString)")
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


func resolve_voice(_ voiceName: String) -> AVSpeechSynthesisVoice {
    let voiceName = voiceName.lowercased()
    for voice in AVSpeechSynthesisVoice.speechVoices() {
        if voice.name.lowercased() == voiceName {
            return voice
        }
    }
    fatalError("Unknown voice: \(voiceName)")
}

func serve(_ settings: Settings) async {
    let channels = settings.channels.map {
        let voice = resolve_voice($0.voice)
        return Channel(
            pitch: $0.pitch,
            rate: $0.rate,
            volume: $0.volume,
            voice: voice,
            synth: AVSpeechSynthesizer()
        )
    }
    let speechManager = SpeechManager(channels: channels)
    let jsonDecoder = JSONDecoder()
    print("Have \(channels.count) channels")
    
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


