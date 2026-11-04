import SwiftUI
import AppKit
import AVFoundation

// MARK: - Errores

struct UVCCError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Puente a uvcc

final class UVCC {
    let node: String
    let script: String

    init(node: String, script: String) {
        self.node = node
        self.script = script
    }

    /// Busca uvcc y su node sin depender del PATH, que al lanzar desde Finder viene vacio.
    /// Primero el motor embebido en Resources: asi la app no depende de npm ni de nvm.
    static func locate() -> UVCC? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        if let res = Bundle.main.resourceURL {
            let node = res.appendingPathComponent("node").path
            let script = res.appendingPathComponent("engine/node_modules/uvcc/dist/index.js").path
            if fm.isExecutableFile(atPath: node), fm.fileExists(atPath: script) {
                return UVCC(node: node, script: script)
            }
        }
        var dirs: [String] = []

        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            for v in versions.sorted(by: >) { dirs.append(nvmRoot + "/" + v + "/bin") }
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.volta/bin", home + "/.local/bin"]

        var nodeFallback: String? = nil
        for d in dirs where fm.isExecutableFile(atPath: d + "/node") {
            nodeFallback = d + "/node"
            break
        }

        for d in dirs {
            let uvcc = d + "/uvcc"
            guard fm.isExecutableFile(atPath: uvcc) else { continue }
            let sibling = d + "/node"
            let node = fm.isExecutableFile(atPath: sibling) ? sibling : nodeFallback
            guard let node = node else { continue }
            let real = URL(fileURLWithPath: uvcc).resolvingSymlinksInPath().path
            return UVCC(node: node, script: real)
        }
        return nil
    }

    @discardableResult
    func run(_ args: [String], input: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script] + args

        var env = ProcessInfo.processInfo.environment
        let nodeDir = URL(fileURLWithPath: node).deletingLastPathComponent().path
        env["PATH"] = nodeDir + ":/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        do { try p.run() } catch {
            throw UVCCError(message: "No se pudo ejecutar uvcc: " + error.localizedDescription)
        }

        if let input = input, let data = input.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "campanel.uvcc.read", attributes: .concurrent)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        p.waitUntilExit()
        group.wait()

        if p.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? ""
            let first = err.split(separator: "\n").first.map(String.init)
                ?? "uvcc devolvió código \(p.terminationStatus)"
            throw UVCCError(message: first)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    func decode<T: Decodable>(_ args: [String], as type: T.Type) throws -> T {
        let out = try run(args)
        guard let data = out.data(using: .utf8), !data.isEmpty else {
            throw UVCCError(message: "uvcc no devolvió datos")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Modelo

struct Device: Identifiable, Hashable, Codable {
    let name: String
    let vendor: Int
    let product: Int
    let address: Int

    var id: String { "\(vendor)-\(product)-\(address)" }
    /// Clave estable por modelo: los presets sobreviven a un cambio de puerto.
    var modelKey: String { String(format: "%04x-%04x", vendor, product) }
    var hexLabel: String { String(format: "0x%04X:0x%04X", vendor, product) }
    var args: [String] {
        ["--vendor", "0x" + String(vendor, radix: 16),
         "--product", "0x" + String(product, radix: 16),
         "--address", String(address)]
    }
}

/// Un control UVC puede traer un numero o varios: absolute_pan_tilt devuelve [pan, tilt].
/// Un tipo inesperado queda vacio y se omite, para que un solo control no tumbe toda la lectura.
struct UVCValue: Decodable {
    let numbers: [Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(Int.self) {
            numbers = [one]
        } else {
            numbers = (try? c.decode([Int].self)) ?? []
        }
    }
}

struct UVCRange: Decodable {
    let min: UVCValue
    let max: UVCValue
}

struct Opt: Identifiable, Hashable {
    let value: Int
    let label: String
    var id: Int { value }
}

enum Kind {
    case range(Int, Int)
    case toggle
    case options([Opt])
}

struct Ctl: Identifiable {
    let key: String
    let label: String
    let group: String
    let kind: Kind
    var value: Int
    var id: String { key }
}

enum Meta {
    static let groupOrder = ["Exposición", "Color", "Imagen", "Enfoque y encuadre", "Otros"]

    /// etiqueta y grupo por control UVC. Cubre mas controles de los que expone una sola camara.
    static let info: [String: (String, String)] = [
        "auto_exposure_mode":              ("Modo de exposición", "Exposición"),
        "auto_exposure_priority":          ("Prioridad de exposición", "Exposición"),
        "absolute_exposure_time":          ("Tiempo de exposición", "Exposición"),
        "gain":                            ("Ganancia", "Exposición"),
        "backlight_compensation":          ("Compensación de contraluz", "Exposición"),
        "auto_white_balance_temperature":  ("Balance de blancos", "Color"),
        "white_balance_temperature":       ("Temperatura de color", "Color"),
        "auto_white_balance_component":    ("Balance de blancos por componente", "Color"),
        "saturation":                      ("Saturación", "Color"),
        "hue":                             ("Tono", "Color"),
        "auto_hue":                        ("Tono automático", "Color"),
        "brightness":                      ("Brillo", "Imagen"),
        "contrast":                        ("Contraste", "Imagen"),
        "auto_contrast":                   ("Contraste automático", "Imagen"),
        "gamma":                           ("Gamma", "Imagen"),
        "sharpness":                       ("Nitidez", "Imagen"),
        "power_line_frequency":            ("Frecuencia de red", "Imagen"),
        "auto_focus":                      ("Enfoque automático", "Enfoque y encuadre"),
        "absolute_focus":                  ("Enfoque", "Enfoque y encuadre"),
        "absolute_zoom":                   ("Zoom", "Enfoque y encuadre"),
        "absolute_pan":                    ("Paneo", "Enfoque y encuadre"),
        "absolute_tilt":                   ("Inclinación", "Enfoque y encuadre"),
        "absolute_roll":                   ("Rotación", "Enfoque y encuadre"),
        "absolute_iris":                   ("Diafragma", "Exposición")
    ]

    /// controles sin rango: se pintan como menu, con la semantica del estandar UVC.
    static let options: [String: [Opt]] = [
        "auto_exposure_mode": [
            Opt(value: 1, label: "Manual"),
            Opt(value: 2, label: "Automático"),
            Opt(value: 4, label: "Prioridad de obturador"),
            Opt(value: 8, label: "Prioridad de apertura")
        ],
        "auto_exposure_priority": [
            Opt(value: 0, label: "FPS fijos"),
            Opt(value: 1, label: "FPS variables")
        ],
        "auto_white_balance_temperature": [
            Opt(value: 0, label: "Manual"),
            Opt(value: 1, label: "Automático")
        ],
        "auto_focus": [
            Opt(value: 0, label: "Manual"),
            Opt(value: 1, label: "Automático")
        ],
        "power_line_frequency": [
            Opt(value: 0, label: "Desactivada"),
            Opt(value: 1, label: "50 Hz"),
            Opt(value: 2, label: "60 Hz")
        ]
    ]

    /// El orden importa: los modos automaticos se apagan antes de fijar el valor manual.
    static let applyOrder = [
        "power_line_frequency",
        "auto_exposure_mode", "auto_exposure_priority", "absolute_exposure_time", "gain",
        "auto_white_balance_temperature", "white_balance_temperature",
        "auto_focus", "absolute_focus", "absolute_zoom", panKey, tiltKey,
        "backlight_compensation", "brightness", "contrast", "gamma", "hue", "saturation", "sharpness"
    ]

    /// Modos que cada modelo acepta de verdad, cuando difieren del estandar. Probado en hardware:
    /// la C920 (046d:0892) solo admite 1 y 8, y su modo 8 es el automatico normal.
    static let modelOptions: [String: [String: [Opt]]] = [
        "046d-0892": [
            "auto_exposure_mode": [
                Opt(value: 1, label: "Manual"),
                Opt(value: 8, label: "Automático")
            ]
        ]
    ]

    static func options(for key: String, model: String) -> [Opt]? {
        return modelOptions[model]?[key] ?? options[key]
    }

    // --- pan y tilt: en USB son un solo control con dos valores; en la app, dos sliders ---

    static let panTiltKey = "absolute_pan_tilt"
    static let panKey = "absolute_pan"
    static let tiltKey = "absolute_tilt"

    /// Pasa los valores de uvcc a un entero por control. Omite los que no se saben representar.
    static func flatten(_ raw: [String: UVCValue]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, value) in raw {
            if key == panTiltKey, value.numbers.count == 2 {
                out[panKey] = value.numbers[0]
                out[tiltKey] = value.numbers[1]
            } else if value.numbers.count == 1 {
                out[key] = value.numbers[0]
            }
        }
        return out
    }

    static func flatten(_ raw: [String: UVCRange]) -> [String: (min: Int, max: Int)] {
        var out: [String: (min: Int, max: Int)] = [:]
        for (key, range) in raw {
            let lo = range.min.numbers, hi = range.max.numbers
            if key == panTiltKey, lo.count == 2, hi.count == 2 {
                out[panKey] = (lo[0], hi[0])
                out[tiltKey] = (lo[1], hi[1])
            } else if lo.count == 1, hi.count == 1 {
                out[key] = (lo[0], hi[0])
            }
        }
        return out
    }

    /// Argumentos de `uvcc set`. Mover pan o tilt obliga a enviar los dos valores.
    static func setArgs(_ key: String, in values: [String: Int]) -> [String] {
        if key == panKey || key == tiltKey {
            return ["set", panTiltKey, String(values[panKey] ?? 0), String(values[tiltKey] ?? 0)]
        }
        return ["set", key, String(values[key] ?? 0)]
    }

    // --- controles que dependen de un modo automatico ---

    /// La camara rechaza escribir estos controles mientras su modo automatico esta activo.
    static func isLocked(_ key: String, in values: [String: Int]) -> Bool {
        switch key {
        case "absolute_exposure_time":
            return isAutoExposure(values)
        case "white_balance_temperature":
            return (values["auto_white_balance_temperature"] ?? 0) != 0
        case "absolute_focus":
            return (values["auto_focus"] ?? 0) != 0
        default:
            return false
        }
    }

    static func isAutoExposure(_ values: [String: Int]) -> Bool {
        let mode = values["auto_exposure_mode"]
        return mode == 2 || mode == 8
    }

    /// Controles cuyo valor lo decide la camara con estos modos: no se puede esperar que coincida.
    static func isDriven(_ key: String, in values: [String: Int]) -> Bool {
        return isLocked(key, in: values) || (key == "gain" && isAutoExposure(values))
    }

    /// Valor con unidades. UVC fija las de exposicion (100 us) y pan/tilt (segundos de arco).
    static func format(_ key: String, _ value: Int) -> String {
        let oneDecimal = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).grouping(.never)
        switch key {
        case "absolute_exposure_time":
            return (Double(value) / 10).formatted(oneDecimal) + " ms"
        case "white_balance_temperature":
            return "\(value) K"
        case panKey, tiltKey:
            return (Double(value) / 3600).formatted(oneDecimal) + "°"
        default:
            return String(value)
        }
    }

    static func label(_ key: String) -> String {
        if let i = info[key] { return i.0 }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func group(_ key: String) -> String {
        return info[key]?.1 ?? "Otros"
    }
}

// MARK: - Persistencia

struct Config: Codable {
    var presets: [String: [String: [String: Int]]] = [:]   // modelo -> preset -> valores
    var baseline: [String: [String: Int]] = [:]            // modelo -> valores del primer arranque
    var loginPreset: [String: String] = [:]                // modelo -> preset aplicado al iniciar sesión
    var engine: String? = nil                              // ruta del uvcc en uso, para diagnostico
}

enum Paths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CamPanel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    static var launchAgentsDir: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Estado

final class Store: ObservableObject {
    @Published var uvcc: UVCC? = nil
    @Published var devices: [Device] = []
    @Published var device: Device? = nil
    @Published var controls: [Ctl] = []
    @Published var presetNames: [String] = []
    @Published var selectedPreset: String = ""
    @Published var loginEnabled: Bool = false
    @Published var status: String = ""
    @Published var isError: Bool = false
    @Published var busy: Bool = false

    /// Control que se esta arrastrando: una relectura no debe moverlo bajo el dedo.
    var editingKey: String? = nil

    private var config = Config()
    private let work = DispatchQueue(label: "campanel.work")

    init() {
        uvcc = UVCC.locate()
        loadConfig()
        let resolved = uvcc.map { $0.node + " + " + $0.script }
        if config.engine != resolved {
            config.engine = resolved
            saveConfig()
        }
        refreshDevices()
    }

    // --- config en disco ---

    private func loadConfig() {
        if let data = try? Data(contentsOf: Paths.configFile),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
        }
    }

    private func saveConfig() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) {
            try? data.write(to: Paths.configFile, options: .atomic)
        }
    }

    // --- helpers de UI ---

    private func report(_ text: String, error: Bool = false) {
        DispatchQueue.main.async {
            self.status = text
            self.isError = error
        }
    }

    func value(_ key: String) -> Int {
        return controls.first(where: { $0.key == key })?.value ?? 0
    }

    func setLocal(_ key: String, _ v: Int) {
        guard let i = controls.firstIndex(where: { $0.key == key }) else { return }
        controls[i].value = v
    }

    var currentValues: [String: Int] {
        var out: [String: Int] = [:]
        for c in controls { out[c.key] = c.value }
        return out
    }

    var loginPresetName: String? {
        return device.flatMap { config.loginPreset[$0.modelKey] }
    }

    func isLocked(_ key: String) -> Bool {
        return Meta.isLocked(key, in: currentValues)
    }

    private func readValues(_ uvcc: UVCC, _ d: Device) throws -> [String: Int] {
        return Meta.flatten(try uvcc.decode(d.args + ["export"], as: [String: UVCValue].self))
    }

    /// Actualiza los valores sin rehacer la lista, con lo que la camara dice tener.
    private func merge(_ values: [String: Int], from d: Device) {
        guard device?.id == d.id else { return }
        for i in controls.indices where controls[i].key != editingKey {
            if let v = values[controls[i].key] { controls[i].value = v }
        }
    }

    private func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.contains("LIBUSB_TRANSFER_STALL") ? "la cámara rechazó ese valor" : text
    }

    // --- dispositivos y controles ---

    func refreshDevices() {
        guard let uvcc = uvcc else {
            report("uvcc no está instalado. Ejecuta: npm i -g uvcc", error: true)
            return
        }
        busy = true
        work.async {
            do {
                let found = try uvcc.decode(["devices"], as: [Device].self)
                DispatchQueue.main.async {
                    self.devices = found
                    self.busy = false
                    if let d = self.device, found.contains(where: { $0.id == d.id }) {
                        self.loadControls()
                    } else if let first = found.first {
                        self.select(first)
                    } else {
                        self.controls = []
                        self.report("No hay cámaras UVC conectadas", error: true)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.busy = false }
                self.report(error.localizedDescription, error: true)
            }
        }
    }

    func select(_ d: Device) {
        device = d
        presetNames = (config.presets[d.modelKey]?.keys.sorted()) ?? []
        selectedPreset = config.loginPreset[d.modelKey] ?? presetNames.first ?? ""
        loginEnabled = config.loginPreset[d.modelKey] != nil
        loadControls()
    }

    func loadControls() {
        guard let uvcc = uvcc, let d = device else { return }
        busy = true
        work.async {
            do {
                let values = try self.readValues(uvcc, d)
                let ranges = Meta.flatten(try uvcc.decode(d.args + ["ranges"], as: [String: UVCRange].self))

                var list: [Ctl] = []
                for (key, value) in values {
                    let kind: Kind
                    if let r = ranges[key] {
                        kind = (r.min == 0 && r.max == 1) ? .toggle : .range(r.min, r.max)
                    } else if let opts = Meta.options(for: key, model: d.modelKey) {
                        kind = .options(opts)
                    } else {
                        kind = .range(0, max(value, 1))
                    }
                    list.append(Ctl(key: key, label: Meta.label(key), group: Meta.group(key), kind: kind, value: value))
                }
                list.sort { a, b in
                    let ga = Meta.groupOrder.firstIndex(of: a.group) ?? 99
                    let gb = Meta.groupOrder.firstIndex(of: b.group) ?? 99
                    if ga != gb { return ga < gb }
                    let ia = Meta.applyOrder.firstIndex(of: a.key) ?? 99
                    let ib = Meta.applyOrder.firstIndex(of: b.key) ?? 99
                    if ia != ib { return ia < ib }
                    return a.key < b.key
                }

                DispatchQueue.main.async {
                    self.controls = list
                    self.busy = false
                    if self.config.baseline[d.modelKey] == nil {
                        self.config.baseline[d.modelKey] = values
                        self.saveConfig()
                    }
                    self.report("\(list.count) controles leídos de \(d.name)")
                }
            } catch {
                DispatchQueue.main.async { self.busy = false }
                self.report(error.localizedDescription, error: true)
            }
        }
    }

    // --- escritura ---

    func commit(_ key: String) {
        guard let uvcc = uvcc, let d = device else { return }
        let v = value(key)
        let args = Meta.setArgs(key, in: currentValues)
        work.async {
            do {
                try uvcc.run(d.args + args)
                // La camara redondea (exposicion 201 queda en 156) y un cambio de modo mueve otros
                // controles: lo que se muestra debe ser lo que ella dice, no lo que se pidio.
                let now = try self.readValues(uvcc, d)
                DispatchQueue.main.async { self.merge(now, from: d) }
                if let real = now[key], real != v {
                    self.report("\(Meta.label(key)): \(Meta.format(key, real)) (la cámara ajustó \(Meta.format(key, v)))")
                } else {
                    self.report("\(Meta.label(key)): \(Meta.format(key, v))")
                }
            } catch {
                self.report("\(Meta.label(key)): " + self.describe(error), error: true)
                DispatchQueue.main.async { self.loadControls() }
            }
        }
    }

    static func orderedJSON(_ values: [String: Int]) -> String {
        var keys = Meta.applyOrder.filter { values[$0] != nil }
        keys += values.keys.filter { !Meta.applyOrder.contains($0) }.sorted()
        var lines: [String] = []
        for key in keys {
            if key == Meta.panKey || key == Meta.tiltKey {
                // Pan y tilt viajan juntos, en la posicion del primero que aparezca.
                let pair = "[\(values[Meta.panKey] ?? 0), \(values[Meta.tiltKey] ?? 0)]"
                let line = "  \"\(Meta.panTiltKey)\": \(pair)"
                if !lines.contains(line) { lines.append(line) }
            } else {
                lines.append("  \"\(key)\": \(values[key]!)")
            }
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }

    /// Lo que no quedo como se pidio, sin contar lo que decide un modo automatico.
    static func mismatches(wanted: [String: Int], got: [String: Int]) -> [String] {
        return wanted.keys.sorted().compactMap { key in
            guard !Meta.isDriven(key, in: wanted), let real = got[key], real != wanted[key] else { return nil }
            return "\(Meta.label(key)) quedó en \(real), no \(wanted[key]!)"
        }
    }

    func apply(_ values: [String: Int], label: String) {
        guard let uvcc = uvcc, let d = device else { return }
        let payload = Store.orderedJSON(values)
        busy = true
        work.async {
            do {
                // uvcc import escribe en paralelo e ignora los errores de cada control. La primera
                // pasada deja fijos los modos; la segunda escribe los valores que dependian de ellos.
                try uvcc.run(d.args + ["import"], input: payload)
                try uvcc.run(d.args + ["import"], input: payload)
                let off = Store.mismatches(wanted: values, got: try self.readValues(uvcc, d))
                if off.isEmpty {
                    self.report("Aplicado: \(label)")
                } else {
                    self.report("Aplicado \(label), pero " + off.joined(separator: "; "), error: true)
                }
            } catch {
                self.report(self.describe(error), error: true)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.loadControls()
            }
        }
    }

    // --- presets ---

    func applySelectedPreset() {
        guard let d = device,
              let values = config.presets[d.modelKey]?[selectedPreset] else { return }
        apply(values, label: selectedPreset)
    }

    func savePreset(named name: String) {
        guard let d = device else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var forModel = config.presets[d.modelKey] ?? [:]
        forModel[clean] = currentValues
        config.presets[d.modelKey] = forModel
        saveConfig()
        presetNames = forModel.keys.sorted()
        selectedPreset = clean
        if loginEnabled { enableLogin(true) }
        report("Preset guardado: \(clean)")
    }

    func deleteSelectedPreset() {
        guard let d = device, !selectedPreset.isEmpty else { return }
        let gone = selectedPreset
        config.presets[d.modelKey]?.removeValue(forKey: gone)
        if config.loginPreset[d.modelKey] == gone {
            config.loginPreset.removeValue(forKey: d.modelKey)
            loginEnabled = false
            removeLaunchAgent(for: d)
        }
        saveConfig()
        presetNames = (config.presets[d.modelKey]?.keys.sorted()) ?? []
        selectedPreset = presetNames.first ?? ""
        report("Preset eliminado: \(gone)")
    }

    func restoreBaseline() {
        guard let d = device, let values = config.baseline[d.modelKey] else {
            report("No hay valores iniciales guardados para esta cámara", error: true)
            return
        }
        apply(values, label: "valores iniciales")
    }

    // --- arranque de sesion ---

    func enableLogin(_ on: Bool) {
        guard let d = device else { return }
        if on {
            guard !selectedPreset.isEmpty,
                  let values = config.presets[d.modelKey]?[selectedPreset] else {
                loginEnabled = false
                report("Guarda un preset antes de activarlo al iniciar sesión", error: true)
                return
            }
            config.loginPreset[d.modelKey] = selectedPreset
            loginEnabled = true
            saveConfig()
            writeLaunchAgent(for: d, values: values)
        } else {
            config.loginPreset.removeValue(forKey: d.modelKey)
            loginEnabled = false
            saveConfig()
            removeLaunchAgent(for: d)
        }
    }

    private func agentLabel(_ d: Device) -> String { "local.campanel." + d.modelKey }

    private func writeLaunchAgent(for d: Device, values: [String: Int]) {
        guard let uvcc = uvcc else { return }
        let dir = Paths.supportDir
        let jsonURL = dir.appendingPathComponent("login-\(d.modelKey).json")
        let shURL = dir.appendingPathComponent("login-\(d.modelKey).sh")
        let plistURL = Paths.launchAgentsDir.appendingPathComponent(agentLabel(d) + ".plist")

        try? Store.orderedJSON(values).write(to: jsonURL, atomically: true, encoding: .utf8)

        // La camara puede tardar en enumerar tras el arranque, sobre todo detras de un dock.
        let script = """
        #!/bin/bash
        # Generado por CamPanel. Reaplica el preset "\(selectedPreset)" a \(d.name).
        NODE="\(uvcc.node)"
        UVCC="\(uvcc.script)"
        CFG="\(jsonURL.path)"
        ARGS=(--vendor 0x\(String(d.vendor, radix: 16)) --product 0x\(String(d.product, radix: 16)))
        for _ in $(seq 1 20); do
          if "$NODE" "$UVCC" "${ARGS[@]}" export >/dev/null 2>&1; then
            # Dos pasadas: la primera fija los modos, la segunda los valores que dependen de ellos.
            "$NODE" "$UVCC" "${ARGS[@]}" import < "$CFG"
            "$NODE" "$UVCC" "${ARGS[@]}" import < "$CFG"
            exit $?
          fi
          sleep 3
        done
        exit 0

        """
        try? script.write(to: shURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shURL.path)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(agentLabel(d))</string>
          <key>ProgramArguments</key>
          <array><string>/bin/bash</string><string>\(shURL.path)</string></array>
          <key>RunAtLoad</key><true/>
          <key>StandardOutPath</key><string>\(Paths.supportDir.path)/login.log</string>
          <key>StandardErrorPath</key><string>\(Paths.supportDir.path)/login.log</string>
        </dict>
        </plist>

        """
        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)

        let uid = String(getuid())
        _ = shell(["/bin/launchctl", "bootout", "gui/" + uid + "/" + agentLabel(d)])
        let res = shell(["/bin/launchctl", "bootstrap", "gui/" + uid, plistURL.path])
        if res.0 == 0 {
            report("Se reaplicará \"\(selectedPreset)\" al iniciar sesión")
        } else {
            report("No se pudo registrar el arranque automático: " + res.1, error: true)
        }
    }

    private func removeLaunchAgent(for d: Device) {
        let plistURL = Paths.launchAgentsDir.appendingPathComponent(agentLabel(d) + ".plist")
        _ = shell(["/bin/launchctl", "bootout", "gui/" + String(getuid()) + "/" + agentLabel(d)])
        try? FileManager.default.removeItem(at: plistURL)
        report("Arranque automático desactivado")
    }

    private func shell(_ argv: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus, out)
    }
}

// MARK: - Vista previa en vivo

/// Mantiene la sesion de captura para ver el efecto de cada ajuste mientras se mueve.
final class Preview: ObservableObject {
    let session = AVCaptureSession()
    @Published var running = false
    @Published var denied = false
    private var attachedID: String? = nil
    private let queue = DispatchQueue(label: "campanel.preview")

    func match(_ name: String) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        if let exact = found.first(where: { $0.localizedName == name }) { return exact }
        let lower = name.lowercased()
        if let loose = found.first(where: { $0.localizedName.lowercased().contains(lower) || lower.contains($0.localizedName.lowercased()) }) { return loose }
        return found.first
    }

    func start(deviceNamed name: String) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else { self.denied = true; self.running = false; return }
                self.denied = false
                self.attach(name)
            }
        }
    }

    private func attach(_ name: String) {
        guard let dev = match(name) else { return }
        if attachedID == dev.uniqueID && session.isRunning { running = true; return }

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
            attachedID = dev.uniqueID
        }
        session.commitConfiguration()

        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.running = self.session.isRunning }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.running = false }
        }
    }
}

final class PreviewNSView: NSView {
    let layerPreview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        layerPreview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layerPreview.videoGravity = .resizeAspectFill
        layer?.addSublayer(layerPreview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerPreview.frame = bounds
        CATransaction.commit()
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(session: session) }
    func updateNSView(_ view: PreviewNSView, context: Context) {}
}

// MARK: - Vista principal

struct ContentView: View {
    @ObservedObject var store: Store
    @StateObject private var preview = Preview()
    @State private var showSaveSheet = false
    @State private var showDeleteConfirm = false
    @State private var draftName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 290, ideal: 320, max: 400)
        } detail: {
            detail
                .navigationTitle("CamPanel")
        }
        .toolbar { toolbarContent }
        .frame(minWidth: 860, minHeight: 600)
        .sheet(isPresented: $showSaveSheet) { saveSheet }
        .confirmationDialog(
            "¿Eliminar el preset \"\(store.selectedPreset)\"?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Eliminar", role: .destructive) { store.deleteSelectedPreset() }
        } message: {
            Text("Esta acción no se puede deshacer.")
        }
        .onAppear { syncPreview() }
        .onChange(of: store.device?.id) { _ in syncPreview() }
    }

    private func syncPreview() {
        guard let d = store.device else { preview.stop(); return }
        preview.start(deviceNamed: d.name)
    }

    private func askToSave(named name: String) {
        draftName = name
        showSaveSheet = true
    }

    // --- barra de herramientas ---

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Cámara", selection: Binding(
                get: { store.device?.id ?? "" },
                set: { id in if let d = store.devices.first(where: { $0.id == id }) { store.select(d) } }
            )) {
                if store.devices.isEmpty { Text("Ninguna cámara").tag("") }
                ForEach(store.devices) { d in Text(d.name).tag(d.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help("Cámara")

            Button { store.refreshDevices() } label: {
                Label("Volver a leer", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Volver a leer la cámara (⌘R)")

            Button {
                if preview.running { preview.stop() } else { syncPreview() }
            } label: {
                Label(preview.running ? "Apagar vista previa" : "Encender vista previa",
                      systemImage: preview.running ? "video.fill" : "video.slash")
            }
            .help(preview.running ? "Apagar la vista previa" : "Encender la vista previa")
        }
    }

    // --- barra lateral: vista previa y presets ---

    private var sidebar: some View {
        VStack(spacing: 0) {
            previewBox.padding(12)
            presetList
            Divider()
            presetFooter
        }
    }

    private var previewBox: some View {
        ZStack {
            Color.black
            if preview.running {
                CameraPreview(session: preview.session)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: preview.denied ? "video.slash" : "video")
                        .font(.title2)
                    Text(preview.denied ? "Sin permiso de cámara" : "Vista previa apagada")
                        .font(.caption)
                    if preview.denied {
                        Button("Abrir Ajustes…") { openCameraPrivacy() }
                            .controlSize(.small)
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    private func openCameraPrivacy() {
        let link = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private var presetList: some View {
        List(selection: Binding<String?>(
            get: { store.selectedPreset.isEmpty ? nil : store.selectedPreset },
            set: { if let name = $0 { store.selectedPreset = name } }
        )) {
            Section("Presets") {
                ForEach(store.presetNames, id: \.self) { name in
                    HStack {
                        Text(name).lineLimit(1)
                        Spacer()
                        if store.loginPresetName == name {
                            Image(systemName: "power")
                                .foregroundStyle(.secondary)
                                .help("Se aplica al iniciar sesión")
                        }
                    }
                    .tag(name)
                    .contextMenu {
                        Button("Aplicar") {
                            store.selectedPreset = name
                            store.applySelectedPreset()
                        }
                        Button("Reemplazar con los ajustes actuales…") { askToSave(named: name) }
                        Divider()
                        Button("Eliminar…") {
                            store.selectedPreset = name
                            showDeleteConfirm = true
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.presetNames.isEmpty {
                VStack(spacing: 4) {
                    Text("Sin presets").font(.callout).foregroundStyle(.secondary)
                    Text("Ajusta la cámara y guarda esos valores con +")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var presetFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Aplicar al iniciar sesión", isOn: Binding(
                get: { !store.selectedPreset.isEmpty && store.loginPresetName == store.selectedPreset },
                set: { store.enableLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(store.selectedPreset.isEmpty)

            HStack(spacing: 10) {
                Button { askToSave(named: "") } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(store.controls.isEmpty)
                    .help("Guardar los ajustes actuales como preset (⌘S)")
                Button { showDeleteConfirm = true } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(store.selectedPreset.isEmpty)
                    .help("Eliminar el preset seleccionado")
                Spacer()
                Button("Aplicar") { store.applySelectedPreset() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.selectedPreset.isEmpty || store.busy)
            }
        }
        .padding(12)
    }

    // --- detalle: ajustes de la camara ---

    private var detail: some View {
        Group {
            if store.uvcc == nil {
                missingTool
            } else if store.controls.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Sin controles que mostrar").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(groups, id: \.self) { g in
                        Section(g) {
                            ForEach(store.controls.filter { $0.group == g }) { c in
                                row(for: c)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if store.busy {
                    ProgressView().controlSize(.small)
                } else if store.isError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(store.status)
                    .font(.callout)
                    .foregroundStyle(store.isError ? Color.primary : Color.secondary)
                    .lineLimit(2)
                    .help(store.status)
                Spacer()
                Button("Restaurar valores iniciales") { store.restoreBaseline() }
                    .disabled(store.controls.isEmpty || store.busy)
                    .help("Vuelve a los valores que tenía la cámara la primera vez que CamPanel la leyó")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var missingTool: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text("No encuentro uvcc, el motor que habla con la cámara.")
            Text("npm i -g uvcc")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            Button("Buscar de nuevo") { store.uvcc = UVCC.locate(); store.refreshDevices() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var groups: [String] {
        Meta.groupOrder.filter { g in store.controls.contains { $0.group == g } }
    }

    @ViewBuilder
    private func row(for c: Ctl) -> some View {
        switch c.kind {
        case .toggle:
            Toggle(c.label, isOn: Binding(
                get: { store.value(c.key) != 0 },
                set: { store.setLocal(c.key, $0 ? 1 : 0); store.commit(c.key) }
            ))
            .toggleStyle(.switch)

        case .options(let opts):
            Picker(c.label, selection: Binding(
                get: { store.value(c.key) },
                set: { store.setLocal(c.key, $0); store.commit(c.key) }
            )) {
                ForEach(opts) { o in Text(o.label).tag(o.value) }
            }

        case .range(let lo, let hi):
            // Sin `step`: en macOS dibuja una marca por valor. El binding ya redondea a entero.
            LabeledContent(c.label) {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { Double(store.value(c.key)) },
                            set: { store.setLocal(c.key, Int($0.rounded())) }
                        ),
                        in: Double(lo)...Double(max(hi, lo + 1)),
                        onEditingChanged: { editing in
                            store.editingKey = editing ? c.key : nil
                            if !editing { store.commit(c.key) }
                        }
                    )
                    .labelsHidden()
                    .frame(minWidth: 180)
                    Text(verbatim: Meta.format(c.key, store.value(c.key)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
            }
            .disabled(store.isLocked(c.key))
            .help(store.isLocked(c.key) ? "Lo controla el modo automático. Pásalo a Manual para ajustarlo." : "")
        }
    }

    // --- hoja de guardado ---

    private var saveSheet: some View {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaces = store.presetNames.contains(name)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Guardar preset").font(.headline)
            Text("Se guardan los \(store.controls.count) valores actuales de la cámara.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Nombre", text: $draftName, prompt: Text("Por ejemplo: Reunión, Grabación, Luz de tarde"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            if replaces {
                Text("Reemplazará el preset que ya tiene ese nombre.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancelar") { showSaveSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(replaces ? "Reemplazar" : "Guardar") {
                    store.savePreset(named: draftName)
                    showSaveSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - App

@main
struct CamPanelApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("CamPanel", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 1000, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
