import Foundation

/// Interpret accessible strings, including trigger descendants and Power's live
/// announcement. The catalog supplies identities/order; UI labels supply state.
enum NativeComposerSelection {
    struct Selection: Equatable {
        var model: String
        var effort: String?
        var position: Int?
        var count: Int?
    }
    static let powerNames=["Power","强度","強度","效能","推理强度","推理強度"]
    private static let positionPatterns=["(?<![0-9])([0-9]+)\\s+of\\s+([0-9]+)(?![0-9])", "第\\s*([0-9]+)\\s*[项項個]\\s*[，,]\\s*共\\s*([0-9]+)\\s*[项項個]"]
    enum Speed: String { case standard, fast, ultrafast }

    static func labels(_ model: [String:Any]) -> [String] {
        let names=[model["model"] as? String,model["displayName"] as? String].compactMap { $0 }
        return Array(Set(names + names.compactMap { name in
            for prefix in ["gpt-", "gpt "] where name.lowercased().hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
            return nil
        }))
    }
    private static func matches(_ text: String, labels: [(String,String)]) -> Set<String> {
        let candidates=labels.flatMap { id,label -> [(String,NSRange)] in
            guard !label.isEmpty,
                  let re=try? NSRegularExpression(pattern:"(?<![\\p{L}\\p{N}_.-])"+NSRegularExpression.escapedPattern(for:label)+"(?![\\p{L}\\p{N}_.-])", options:.caseInsensitive) else { return [] }
            return re.matches(in:text,range:NSRange(text.startIndex...,in:text)).map { (id,$0.range) }
        }
        // A long model/effort label may contain a shorter one. Separate,
        // contradictory labels must still be rejected, not hidden by length.
        return Set(candidates.filter { candidate in
            !candidates.contains { other in other.1.length > candidate.1.length && NSIntersectionRange(other.1,candidate.1) == candidate.1 }
        }.map(\.0))
    }
    static func parse(_ texts:[String], models:[[String:Any]]) -> Selection? {
        let text=texts.joined(separator:" ")
        let modelLabels=models.filter { $0["hidden"] as? Bool != true }.flatMap { model -> [(String,String)] in
            guard let id=model["model"] as? String else { return [] }
            return labels(model).map { (id,$0) }
        }
        let ids=matches(text,labels:modelLabels)
        guard ids.count == 1, let id=ids.first, let model=models.first(where:{$0["model"] as? String == id}) else { return nil }
        let translated:[String:[String]]=["none":["None","无","無"],"minimal":["Minimal","最低","极低","極低"],"low":["Low","Light","低","轻度","輕度"],"medium":["Medium","中","中等"],"high":["High","高"],"xhigh":["Extra high","超高","极高","極高"],"max":["Max","最高"],"ultra":["Ultra"]]
        let efforts=(model["supportedReasoningEfforts"] as? [[String:Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
        let found=matches(text,labels:efforts.flatMap { effort in ((translated[effort] ?? [])+[effort]).map { (effort,$0) } })
        guard found.count <= 1 else { return nil }
        var result=Selection(model:id,effort:found.first)
        let announcements=positionPatterns.flatMap { pattern in
            (try! NSRegularExpression(pattern:pattern,options:.caseInsensitive)).matches(in:text,range:NSRange(text.startIndex...,in:text))
        }
        let positions=announcements.compactMap { match -> [Int]? in
            let s=text as NSString
            guard let position=Int(s.substring(with:match.range(at:1))),let count=Int(s.substring(with:match.range(at:2))) else { return nil }
            return [position,count]
        }
        guard positions.count == announcements.count else { return nil }
        if let value=positions.first {
            guard positions.allSatisfy({ $0 == value }),value[1] == efforts.count,value[0] > 0,value[0] <= efforts.count,
                  let effort=result.effort,efforts[value[0]-1] == effort else { return nil }
            result.position=value[0]; result.count=value[1]
        }
        return result
    }
    static func power(_ texts:[String], models:[[String:Any]]) -> Selection? {
        let announcements=texts.filter { text in positionPatterns.contains { text.range(of:$0,options:.regularExpression) != nil } }
        let selections=announcements.compactMap { parse([$0],models:models) }.filter { $0.position != nil && $0.effort != nil }
        guard selections.count == announcements.count,let first=selections.first,selections.allSatisfy({$0 == first}) else { return nil }
        return first
    }
    static func speed(_ texts:[String]) -> Speed? {
        var values=Set<String>()
        for text in texts {
            let words=text.lowercased().components(separatedBy:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"·:："))).filter { !$0.isEmpty }
            switch words.last {
            case "ultrafast","超快","极速","極速": values.insert(Speed.ultrafast.rawValue)
            case "fast","快速": values.insert(Speed.fast.rawValue)
            case "standard","标准","標準": values.insert(Speed.standard.rawValue)
            default: break
            }
        }
        return values.count == 1 ? values.first.flatMap(Speed.init) : nil
    }
    static func sliderValue(selection:Selection, effort:String, models:[[String:Any]], minimum:Double?, maximum:Double?) -> Double? {
        guard let definition=models.first(where:{$0["model"] as? String == selection.model}),
              let minimum,let maximum,minimum.isFinite,maximum.isFinite,maximum > minimum else { return nil }
        let efforts=(definition["supportedReasoningEfforts"] as? [[String:Any]] ?? []).compactMap {$0["reasoningEffort"] as? String}
        guard Set(efforts).count == efforts.count, selection.count == efforts.count,let position=selection.position,
              efforts.indices.contains(position-1),efforts[position-1] == selection.effort,let to=efforts.firstIndex(of:effort),efforts.count > 1 else { return nil }
        return minimum+(maximum-minimum)*Double(to)/Double(efforts.count-1)
    }
}
