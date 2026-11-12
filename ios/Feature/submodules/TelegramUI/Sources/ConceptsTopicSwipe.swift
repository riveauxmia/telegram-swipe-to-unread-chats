import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import ObjectiveC
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import AvatarNode
import TelegramPresentationData
import ChatListUI
import ChatMessageItemView
import ComponentFlow
import GlassBackgroundComponent
import TelegramNotices
import ChatTitleView
import TelegramStringFormatting
import AnimatedStickerNode
import ChatMessageAnimatedStickerItemNode
import ChatAvatarNavigationNode
import EdgeEffect

// Next Chat Swipe concept (`--concepts-topic-swipe`).
// The threshold and the haptic are the stock ones (ChatHistoryListNode). Pull up at the end of any chat: past the
// threshold a panel stays on screen — a row of unread chats of the current folder at the bottom (the freshest first,
// muted ones last) and, above it, the real preview of the selected chat (ChatController in previewing mode, the same
// one as on a long press in the chat list). Swipe the preview or drag the row to go through the chats; tap the
// preview — it grows into the real chat. The first item of the row turns the preview into the list of all unread
// chats. Tap the dimmed area or pull back below the threshold — cancel.
// Entry points in ChatHistoryListNode: `overscrollUpdated`, `consumeRelease`, `landing`; in ChatController: `offersPull`.
// Comments below are partly in Russian (working notes with the version numbers of the recording).

enum ConceptsTopicSwipe {
    static let isEnabled: Bool = CommandLine.arguments.contains("--concepts-topic-swipe")
    private static var sessionKey: UInt8 = 0

    private static func session(listNode: ChatHistoryListNodeImpl, chatNode: ChatControllerNode?) -> ConceptsTopicSwipeSession? {
        guard self.isEnabled else {
            return nil
        }
        if let session = objc_getAssociatedObject(listNode, &self.sessionKey) as? ConceptsTopicSwipeSession {
            return session
        }
        guard let chatNode else {
            return nil
        }
        let session = ConceptsTopicSwipeSession(listNode: listNode, chatNode: chatNode)
        objc_setAssociatedObject(listNode, &self.sessionKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return session
    }

    /// Каждое изменение оттягивания в конце чата; `control` — родная плашка (nil — убрана).
    static func overscrollUpdated(listNode: ChatHistoryListNodeImpl, chatNode: ChatControllerNode?, progress: CGFloat, control: UIView?) {
        self.session(listNode: listNode, chatNode: chatNode)?.overscrollUpdated(progress: progress, control: control)
    }

    /// Отпускание пальца. true — концепт забрал отпускание, родное «открыть следующий» не выполняется.
    static func consumeRelease(listNode: ChatHistoryListNodeImpl) -> Bool {
        return self.session(listNode: listNode, chatNode: nil)?.consumeRelease() ?? false
    }

    /// v30: родная «посадка» оттягивания (0,3 с держит чат приподнятым, затем 0,2 с опускает) шла под размытием
    /// панели — фон за ней заметно менялся. Пока панель стоит, чат держится приподнятым (`hold`), посадка — когда
    /// панель уходит (чат открыт поверх или панель закрыта).
    static func landing(listNode: ChatHistoryListNodeImpl, hold: () -> Void, land: @escaping () -> Void) {
        if let session = self.session(listNode: listNode, chatNode: nil), session.deferLanding(land) {
            hold()
        } else {
            land()
        }
    }

    /// Подготовить панель для чата, открытого сейчас сверху (ролик: перед каждым оттягиванием, пока экран стоит).
    static func prewarm(context: AccountContext) {
        guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController, let chat = navigationController.topViewController as? ChatControllerImpl else {
            return
        }
        self.session(listNode: chat.chatDisplayNode.historyNode, chatNode: chat.chatDisplayNode)?.prewarm()
    }

    /// Сессия чата, открытого сейчас сверху (для автопилота).
    static func currentSession(context: AccountContext) -> ConceptsTopicSwipeSession? {
        guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController, let chat = navigationController.topViewController as? ChatControllerImpl else {
            return nil
        }
        return objc_getAssociatedObject(chat.chatDisplayNode.historyNode, &self.sessionKey) as? ConceptsTopicSwipeSession
    }

    /// Оттягивание в конце любого обычного чата (родное — только в каналах). Точка входа в ChatController.
    static func offersPull(mode: ChatControllerPresentationMode, chatLocation: ChatLocation) -> Bool {
        guard self.isEnabled, case .standard(.default) = mode, case .peer = chatLocation else {
            return false
        }
        return true
    }
}


// MARK: - Движение (правила роликов: базовый изинг 450/300 мс, родная пружина 440/42)

/// Tuning values used for the recording (the fallbacks at the call sites are older defaults).
enum ConceptsTopicSwipeTune {
    static let values: [String: Double] = [
        "flipZeta": 0.999,
        "flipDur": 0.45,
        "flickDur": 0.3,
        "ctlDur": 0.25,
        "ctlBlur": 8.0,
        "ctlWait": 0.0,
        "blurDur": 0.22,
        "scrubSteps": 5.0,
        "scrubHold": 0.0,
        "scrubDur": 0.45,
        "scrubK": 20.0,
        "swapDur": 0.2,
        "embedDelay": 0.05,
        "embedDelayList": 0.05,
        "scrubX1": 0.1,
        "scrubY1": 0.05,
        "scrubX2": 0.9,
        "scrubY2": 0.95,
        "scrubCut": 1.0,
        "pullCut": 0.8,
        "ctlScale": 0.9,
        "shift": -0.5,
        "unparkNext": 0.0,
        "flipX2": 0.35,
        "swapGap": 0.25,
        "pullRing": 0.47,
        "pullSlop": 15.0,
        "scrubSlop": 10.0,
        "pullCut2": 0.8,
        "listScrollAt": -0.1,
        "listScrollDur": 1.5,
        "listTapAt": -1.0,
        "ctlDamp": 22.0,
        "flipDelay": 0.0,
        "rowLock": 1.0,
        "pullX2": 0.5,
        "pull": 265.0,
        "listBounce": 0.4,
        "outlineGlyph": 0.0,
        "glyphSize": 0.0,
        "rowFling": 0.15,
        "settleDur": 0.45,
        "flipY1": 0.4,
        "swapX1": 0.0,
        "swapY1": 0.4,
        "swapX2": 0.0,
        "swapY2": 1.0,
        "scrubEase": 1.0,
        "scrubBounce": 0.0,
        "settleSlope": 5.0,
        "settleX1": 0.18,
        "flipRasterOld": 0.0,
        "flipLinkLead": 0.013,
        "y": 485.0,
        "morphDelay": 0.017,
    ]
    static func v(_ key: String, _ fallback: Double) -> Double {
        return self.values[key] ?? fallback
    }
}

/// v27: градиентные обои всех чатов крутятся одной общей фазой: собираемый заранее чат-превью дёргал перекраску,
/// и вслед за ним менялся фон чата за размытием и карточки. Чаты концепта отвязываем от общей фазы
/// (обои по-прежнему свои; модуль обоев не трогаем — доступ через отражение).
/// v28: когда настоящий чат окончательно подменил карточку (после подмены — пауза ≈0,14 с, контролы ждут её).
enum ConceptsTopicSwipeClock {
    static var chatOpenedAt: Double = 0.0
    static var openStartedAt: Double = 0.0
    /// v29: сколько предпросмотров собирать заранее при подготовке панели (второму жесту нужен один-два).
    static var prewarmPathCount: Int = 9
    /// v31: сколько ближних предпросмотров собирать после закрепления панели. Во втором жесте — 0: сборка шла посреди
    /// свайпа к списку и останавливала кадр на ≈65 мс.
    static var pinnedPrewarmCount: Int = 6
}

enum ConceptsTopicSwipeWallpaper {
    private static var detached = Set<ObjectIdentifier>()

    /// Значение свойства по имени; опционал разворачивается (nil — нет значения).
    private static func child(_ object: Any, _ label: String) -> Any? {
        guard let value = Mirror(reflecting: object).children.first(where: { $0.label == label })?.value else {
            return nil
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first?.value
        }
        return value
    }

    static func gradient(_ node: ChatControllerNode?) -> AnyObject? {
        guard let node, let value = self.child(node.backgroundNode, "gradientBackgroundNode") else {
            return nil
        }
        return value as AnyObject
    }

    static func detach(_ node: ChatControllerNode?) {
        guard let gradient = self.gradient(node), !self.detached.contains(ObjectIdentifier(gradient)) else {
            return
        }
        self.detached.insert(ObjectIdentifier(gradient))
        if let disposable = self.child(gradient, "sharedAnimationSyncDisposable") as? Disposable {
            disposable.dispose()
        }
    }

    static func state(_ node: ChatControllerNode?) -> String {
        guard let gradient = self.gradient(node) else {
            return "-"
        }
        return "\(self.child(gradient, "phase") ?? "?")/\(self.child(gradient, "isAnimating") ?? "?")"
    }
}

private enum ConceptsTopicSwipeMotion {
    /// Базовый изинг пользователя cubic-bezier(0, 0.4, 0, 1): 0,45 с — движение, 0,3 с — прозрачность, затемнение, размытие.
    static func ease(_ duration: Double, delay: Double = 0.0, _ animations: @escaping () -> Void, completion: (() -> Void)? = nil) {
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: UICubicTimingParameters(controlPoint1: CGPoint(x: 0.0, y: 0.4), controlPoint2: CGPoint(x: 0.0, y: 1.0)))
        animator.isUserInteractionEnabled = true
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion({ _ in completion() })
        }
        animator.startAnimation(afterDelay: delay)
    }

    /// Плавный выход без скачка в первом кадре (ease-out cubic): у базового изинга касательная в начале вертикальная,
    /// и крупное появление (карточка, размытие на весь экран) проходит ≈40 % пути за первый кадр — глаз видит рывок.
    static func smooth(_ duration: Double, delay: Double = 0.0, _ animations: @escaping () -> Void, completion: (() -> Void)? = nil) {
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: UICubicTimingParameters(controlPoint1: CGPoint(x: 0.33, y: 1.0), controlPoint2: CGPoint(x: 0.68, y: 1.0)))
        animator.isUserInteractionEnabled = true
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion({ _ in completion() })
        }
        animator.startAnimation(afterDelay: delay)
    }

    /// Мягкий старт и мягкий финиш (0.4, 0, 0.2, 1) — для размытия на весь экран: даже малый радиус размытия
    /// заметно меняет картинку, и любой скачок в первом кадре читается как рывок.
    static func standard(_ duration: Double, delay: Double = 0.0, _ animations: @escaping () -> Void, completion: (() -> Void)? = nil) {
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: UICubicTimingParameters(controlPoint1: CGPoint(x: 0.4, y: 0.0), controlPoint2: CGPoint(x: 0.2, y: 1.0)))
        animator.isUserInteractionEnabled = true
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion({ _ in completion() })
        }
        animator.startAnimation(afterDelay: delay)
    }

    /// Значение cubic-bezier(x1, y1, x2, y2) в момент u ∈ [0, 1] — для покадровых ключей.
    static func curve(_ u: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 40 {
            let m = (lo + hi) / 2
            let x = 3 * (1 - m) * (1 - m) * m * x1 + 3 * (1 - m) * m * m * x2 + m * m * m
            if x < u { lo = m } else { hi = m }
        }
        let m = (lo + hi) / 2
        return 3 * (1 - m) * (1 - m) * m * y1 + 3 * (1 - m) * m * m * y2 + m * m * m
    }

    /// Произвольная кривая Безье.
    static func bezier(_ duration: Double, _ c1: CGPoint, _ c2: CGPoint, delay: Double = 0.0, _ animations: @escaping () -> Void) {
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: UICubicTimingParameters(controlPoint1: c1, controlPoint2: c2))
        animator.isUserInteractionEnabled = true
        animator.addAnimations(animations)
        animator.startAnimation(afterDelay: delay)
    }

    /// Родная пружина Telegram: stiffness 440, damping 42, mass 1, без перелёта (≈0,45 с до покоя).
    /// Пружина без перелёта (критическое затухание, ≈0,4 с): смена карточки при свайпе.
    static func quickSpring(_ animations: @escaping () -> Void) {
        let animator = UIViewPropertyAnimator(duration: 0.4, timingParameters: UISpringTimingParameters(mass: 1.0, stiffness: 600.0, damping: 49.0, initialVelocity: .zero))
        animator.addAnimations(animations)
        animator.startAnimation()
    }

    static func spring(delay: Double = 0.0, _ animations: @escaping () -> Void) {
        let animator = UIViewPropertyAnimator(duration: 0.45, timingParameters: UISpringTimingParameters(mass: 1.0, stiffness: 440.0, damping: 42.0, initialVelocity: .zero))
        animator.isUserInteractionEnabled = true
        animator.addAnimations(animations)
        animator.startAnimation(afterDelay: delay)
    }
}

// MARK: - Наблюдатель касаний

/// Только следит за пальцем: никогда не распознаётся, не мешает и не отменяет чужие жесты.
private final class ConceptsTopicSwipeTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var moved: ((CGPoint) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
        self.delegate = self
    }

    private func report(_ touches: Set<UITouch>) {
        if let touch = touches.first {
            self.moved?(touch.location(in: nil))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.report(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        self.report(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - Сессия одного чата

final class ConceptsTopicSwipeSession: NSObject {
    struct Candidate {
        let peer: EnginePeer
        let unreadCount: Int
        let snippet: String
        let isMuted: Bool
        /// Для строки списка, как в родном списке чатов: время, автор в группе, миниатюра фото.
        var timestamp: Int32 = 0
        var author: String? = nil
        var thumbnail: UIImage? = nil
    }

    enum State {
        case idle
        case tracking
        case pinned
        case opening
    }

    private weak var listNode: ChatHistoryListNodeImpl?
    private weak var chatNode: ChatControllerNode?
    private let context: AccountContext
    private(set) var state: State = .idle
    private var candidates: [Candidate] = []
    private var markedBelowThreshold = false
    private var controlHiddenUntil: CFAbsoluteTime = 0.0
    private var candidatesTimestamp: Double = 0.0
    private var isLoadingCandidates = false
    private var wantsPreparedPanel = false
    private let observer = ConceptsTopicSwipeTouchObserver(target: nil, action: nil)
    private var finger: CGPoint?
    private var trackStart: CGPoint = .zero
    private var panel: ConceptsTopicSwipePanel?
    private var preparedPanel: ConceptsTopicSwipePanel?
    private weak var control: UIView?
    private var controlFading = false
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)

    // Для автопилота: шаг между аватарками, число позиций выбора и точки в координатах окна.
    var stackPitch: CGFloat {
        return self.panel?.itemPitch ?? 44.0
    }

    var stackRowCount: Int {
        return self.panel?.rowCount ?? 0
    }

    func windowPoint(listRow: Int) -> CGPoint? {
        return self.panel?.windowPoint(listRow: listRow)
    }

    func windowPoint(listPeerId: EnginePeer.Id) -> CGPoint? {
        guard let panel = self.panel, let row = panel.candidates.firstIndex(where: { $0.peer.id == listPeerId }) else {
            return nil
        }
        return panel.windowPoint(listRow: row)
    }

    /// Для ролика: список «Все новые» плавно прокручивается вниз без касания.
    func scrollList(by distance: CGFloat, duration: Double) {
        self.panel?.scrollList(by: distance, duration: duration)
    }

    /// Центр выбранной аватарки ряда в координатах окна (для автопилота: листание ряда).
    func rowWindowPoint() -> CGPoint? {
        return self.panel?.rowWindowPoint()
    }

    init(listNode: ChatHistoryListNodeImpl, chatNode: ChatControllerNode) {
        self.listNode = listNode
        self.chatNode = chatNode
        self.context = listNode.context
        super.init()
        self.observer.moved = { [weak self] point in
            self?.fingerMoved(point)
        }
        chatNode.view.addGestureRecognizer(self.observer)
        // Сессия создаётся уже посреди жеста, и новый наблюдатель это касание не увидит: читаем палец
        // и из жеста прокрутки самого списка.
        self.attachPans(listNode.view, depth: 4)
    }

    private func attachPans(_ view: UIView, depth: Int) {
        for recognizer in view.gestureRecognizers ?? [] where recognizer is UIPanGestureRecognizer {
            recognizer.addTarget(self, action: #selector(self.listPanChanged(_:)))
        }
        if depth > 0 {
            for subview in view.subviews {
                self.attachPans(subview, depth: depth - 1)
            }
        }
    }

    @objc private func listPanChanged(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed {
            self.fingerMoved(recognizer.location(in: nil))
        }
    }

    // MARK: Кандидаты

    private static func snippet(_ message: Message) -> String {
        var text = message.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            for media in message.media {
                if media is TelegramMediaImage {
                    text = "Photo"
                } else if media is TelegramMediaPoll {
                    text = "Poll"
                } else if let file = media as? TelegramMediaFile {
                    if file.isSticker {
                        var emoji = ""
                        for attribute in file.attributes {
                            if case let .Sticker(displayText, _, _) = attribute {
                                emoji = displayText
                            }
                        }
                        text = emoji.isEmpty ? "Sticker" : "\(emoji) Sticker"
                    } else if file.isVoice {
                        text = "Voice message"
                    } else if file.isVideo {
                        text = "Video"
                    } else {
                        text = "File"
                    }
                }
                if !text.isEmpty {
                    break
                }
            }
        }
        return text
    }

    /// Все непрочитанные чаты текущей папки (любого типа), кроме открытого: свежие первыми, без звука — в конце.
    private func loadCandidatesIfNeeded() {
        if self.isLoadingCandidates || CFAbsoluteTimeGetCurrent() - self.candidatesTimestamp < 3.0 {
            return
        }
        guard let listNode = self.listNode, let currentPeerId = listNode.chatLocation.peerId else {
            return
        }
        let preferredId = listNode.nextChannelToRead?.peer.id
        let accountPeerId = self.context.account.peerId
        let filterId = self.chatController()?.currentChatListFilter
        let postbox = self.context.account.postbox
        self.isLoadingCandidates = true

        let predicateSignal: Signal<ChatListFilterPredicate?, NoError>
        if let filterId {
            predicateSignal = self.context.engine.peers.currentChatListFilters()
            |> take(1)
            |> map { filters -> ChatListFilterPredicate? in
                for filter in filters {
                    if case let .filter(id, _, _, data) = filter, id == filterId {
                        return chatListFilterPredicate(filter: data, accountPeerId: accountPeerId)
                    }
                }
                return nil
            }
        } else {
            predicateSignal = .single(nil)
        }

        let _ = (predicateSignal
        |> mapToSignal { predicate -> Signal<[Candidate], NoError> in
            return postbox.transaction { transaction -> [Candidate] in
                let peerIds = transaction.getUnreadChatListPeerIds(groupId: .root, filterPredicate: predicate, additionalFilter: nil, stopOnFirstMatch: false)
                var result: [(Candidate, ChatListIndex)] = []
                for peerId in peerIds where peerId != currentPeerId {
                    guard let peer = transaction.getPeer(peerId), let readState = transaction.getCombinedPeerReadState(peerId), readState.count > 0, let (_, index) = transaction.getPeerChatListIndex(peerId) else {
                        continue
                    }
                    var isMuted = false
                    if let settings = transaction.getPeerNotificationSettings(id: peerId) as? TelegramPeerNotificationSettings, case .muted = settings.muteState {
                        isMuted = true
                    }
                    var candidate = Candidate(peer: EnginePeer(peer), unreadCount: Int(readState.count), snippet: "", isMuted: isMuted)
                    if let topIndex = transaction.getTopPeerMessageIndex(peerId: peerId), let message = transaction.getMessage(topIndex.id) {
                        candidate = Candidate(peer: candidate.peer, unreadCount: candidate.unreadCount, snippet: ConceptsTopicSwipeSession.snippet(message), isMuted: isMuted)
                        candidate.timestamp = message.timestamp
                        if let channel = peer as? TelegramChannel, case .group = channel.info {
                            candidate.author = message.flags.contains(.Incoming) ? message.author.flatMap { EnginePeer($0).compactDisplayTitle } : "You"
                        } else if peer is TelegramGroup {
                            candidate.author = message.flags.contains(.Incoming) ? message.author.flatMap { EnginePeer($0).compactDisplayTitle } : "You"
                        }
                        // Миниатюра фото, как в родной строке списка чатов.
                        for media in message.media {
                            if let image = media as? TelegramMediaImage, let representation = image.representations.first(where: { $0.dimensions.width >= 60 }) ?? image.representations.last, let path = postbox.mediaBox.completedResourcePath(representation.resource) {
                                candidate.thumbnail = UIImage(contentsOfFile: path)
                            }
                        }
                    }
                    result.append((candidate, index))
                }
                result.sort(by: { lhs, rhs in
                    if lhs.0.isMuted != rhs.0.isMuted {
                        return !lhs.0.isMuted
                    }
                    return lhs.1 > rhs.1
                })
                var candidates = result.map { $0.0 }
                if let preferredId, let index = candidates.firstIndex(where: { $0.peer.id == preferredId && !$0.isMuted }) {
                    candidates.insert(candidates.remove(at: index), at: 0)
                }
                return Array(candidates.prefix(30))
            }
        }
        |> deliverOnMainQueue).startStandalone(next: { [weak self] candidates in
            guard let self else {
                return
            }
            self.isLoadingCandidates = false
            self.candidatesTimestamp = CFAbsoluteTimeGetCurrent()
            if self.state == .idle {
                // Другой набор чатов — собранная заранее панель устарела.
                if candidates.map({ $0.peer.id }) != self.candidates.map({ $0.peer.id }) || candidates.map({ $0.unreadCount }) != self.candidates.map({ $0.unreadCount }) {
                    self.dropPreparedPanel()
                }
                self.candidates = candidates
                self.offerFirstCandidate()
                if self.wantsPreparedPanel {
                    self.wantsPreparedPanel = false
                    self.preparePanelIfNeeded()
                }
            }
        })
    }

    /// Родная плашка оттягивания в личном чате и группе показывала бы «нет непрочитанных каналов»: следующим
    /// для неё становится первый чат ряда.
    private func offerFirstCandidate() {
        if let listNode = self.listNode, listNode.nextChannelToRead == nil, let first = self.candidates.first {
            listNode.nextChannelToRead = (peer: first.peer, threadData: nil, unreadCount: first.unreadCount, location: .same)
        }
    }

    /// Заранее, пока чат просто открыт, загрузить непрочитанные и собрать панель (скрытой): сборка предпросмотра
    /// посреди оттягивания останавливала кадр ≈0,1 с — оттягивание шло рывком.
    func prewarm() {
        guard self.state == .idle else {
            return
        }
        self.wantsPreparedPanel = true
        self.candidatesTimestamp = 0.0
        self.loadCandidatesIfNeeded()
    }

    // MARK: Жест

    func overscrollUpdated(progress: CGFloat, control: UIView?) {
        if let control {
            if control !== self.control {
                self.controlHiddenUntil = 0.0
            }
            self.control = control
        } else if progress <= 0.0 {
            // Оттягивание закончилось, родной значок убран: следующий жест начинается как обычно.
            self.controlHiddenUntil = 0.0
        }
        switch self.state {
        case .idle:
            if progress > 0.05 {
                self.loadCandidatesIfNeeded()
                self.offerFirstCandidate()
            }
            // Собранная панель не выбрасывается между жестами (её пересборка посреди оттягивания давала рывок);
            // она обновляется, только если поменялся набор непрочитанных.
            if progress > 0.3 {
                self.preparePanelIfNeeded()
            }
            // Панель стартует за кадр до родного порога (0,97): на самом пороге Telegram сам занят (вибрация, значок),
            // и запуск в тот же кадр давал пропуск 2–3 кадров в начале появления.
            if progress >= 0.97, !self.candidates.isEmpty, let control {
                self.beginTracking(control: control)
            }
        case .tracking:
            if progress < 1.0, !self.markedBelowThreshold {
                self.markedBelowThreshold = true
                ConceptsTopicSwipeAutopilot.mark("belowThreshold")
            }
            // Палец вернулся ниже порога — отмена, как сейчас (небольшой запас против дрожания).
            if progress < 0.85 {
                ConceptsTopicSwipeAutopilot.mark("cancel")
                self.cancelTracking()
            }
        case .pinned, .opening:
            break
        }
        if self.state == .idle {
            // После отмены родной значок «следующий канал» до конца этого жеста не возвращается: его аватарка и имя
            // легли бы поверх гаснущего ряда, а после отпускания он всё равно уходит вместе с оттягиванием.
            if let control, control.alpha < 1.0, !self.controlFading, CFAbsoluteTimeGetCurrent() >= self.controlHiddenUntil {
                self.controlFading = true
                ConceptsTopicSwipeMotion.ease(0.2, { control.alpha = 1.0 }, completion: { [weak self] in self?.controlFading = false })
            }
        } else if let control, control.alpha > 0.0, !self.controlFading {
            self.controlFading = true
            ConceptsTopicSwipeMotion.smooth(0.25, { control.alpha = 0.0 }, completion: { [weak self] in self?.controlFading = false })
        }
    }

    func consumeRelease() -> Bool {
        switch self.state {
        case .tracking:
            // Отпустил — панель остаётся: ряд и предпросмотр листаются, тап по предпросмотру открывает чат,
            // на значке «Все новые» — список, тап по строке открывает чат.
            if let panel = self.panel {
                self.state = .pinned
                panel.setPinned()
                ConceptsTopicSwipeAutopilot.mark("pinned")
                self.scheduleChatPreparation()
            }
            return true
        case .opening, .pinned:
            return true
        case .idle:
            return false
        }
    }

    /// Панель собирается заранее, пока палец ещё тянет (без показа): на пороге создание предпросмотра и аватарок
    /// давало заметную остановку кадра ≈80 мс.
    private func preparePanelIfNeeded() {
        guard self.preparedPanel == nil, self.panel == nil, !self.candidates.isEmpty, let chatNode = self.chatNode, let controller = self.chatController() else {
            return
        }
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let layout = controller.currentlyAppliedLayout ?? self.fallbackLayout(size: chatNode.bounds.size)
        // Карточка начинается сразу под строкой состояния: шапка чата под размытием всё равно не читается.
        let topInset = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
        let bottomInset = max(0.0, chatNode.bounds.height - chatNode.inputPanelBackgroundNode.frame.minY)
        // Ряд стоит внизу, поверх панели ввода (она под размытием): ближе к пальцу, карточке больше места.
        let panel = ConceptsTopicSwipePanel(
            context: self.context,
            presentationData: presentationData,
            candidates: self.candidates,
            topInset: topInset,
            bottomY: chatNode.bounds.height - max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom) - 4.0,
            inputPanelHeight: bottomInset,
            layout: layout
        )
        panel.frame = chatNode.bounds
        panel.selectionChanged = { [weak self] fromUser in
            if fromUser {
                self?.selectionFeedback.selectionChanged()
                self?.selectionFeedback.prepare()
            }
            self?.scheduleChatPreparation()
        }
        panel.prepareRequested = { [weak self] candidate in
            self?.prepareChat(for: candidate.peer)
        }
        panel.openRequested = { [weak self] candidate in
            self?.open(candidate: candidate)
        }
        panel.dismissRequested = { [weak self] in
            self?.dismiss()
        }
        // Первая отрисовка панели (предпросмотр, стекло, аватарки) занимала ≈0,12 с, и появление начиналось рывком:
        // панель заранее стоит отрисованной почти прозрачной (1 %, на глаз не видно; касаний до порога не принимает),
        // и на пороге остаётся только проявить её.
        panel.alpha = 0.01
        chatNode.view.addSubview(panel)
        panel.layoutIfNeeded()
        panel.prepareBlur()
        panel.prewarmPath(count: ConceptsTopicSwipeClock.prewarmPathCount)
        self.preparedPanel = panel
    }

    /// v20: настоящий чат выбранной карточки собирается заранее (выбор простоял 0,3 с). Навигация показывает чат только
    /// готовым (≈0,45 с после создания) — дольше раскрытия; собранный заранее встаёт под карточку сразу, и его шапка
    /// с нижней панелью проявляются уже во время раскрытия.
    private var preparedChat: (peerId: EnginePeer.Id, chat: ChatController)?
    private var chatPreparationToken = 0

    private func scheduleChatPreparation() {
        self.chatPreparationToken += 1
        let token = self.chatPreparationToken
        Queue.mainQueue().after(0.3, { [weak self] in
            guard let self, token == self.chatPreparationToken, self.state == .pinned, let panel = self.panel, let peer = panel.selectedCandidate?.peer else {
                return
            }
            // v25: сборка чата (≈50 мс) на ходу ряда роняла кадры — ждём, пока палец отпустит и лента встанет.
            // Так же и при перелистывании карточек: сборка в начале следующего свайпа замораживала экран на ≈0,25 с.
            if panel.isRowScrubbing || CACurrentMediaTime() - panel.rowScrubEndTime < 0.45 || panel.isCardMoving {
                self.chatPreparationToken -= 1
                self.scheduleChatPreparation()
                return
            }
            self.prepareChat(for: peer)
        })
    }

    private func prepareChat(for peer: EnginePeer) {
        guard self.preparedChat?.peerId != peer.id, let chatNode = self.chatNode, let controller = self.chatController() else {
            return
        }
        let chat = self.context.sharedContext.makeChatController(context: self.context, chatLocation: .peer(id: peer.id), subject: nil, botStart: nil, mode: .standard(.default), params: nil)
        if ConceptsTopicSwipeAutopilot.isRecording {
            chat.canReadHistory.set(false)
        }
        let layout = controller.currentlyAppliedLayout ?? self.fallbackLayout(size: chatNode.bounds.size)
        chat.view.frame = CGRect(origin: .zero, size: layout.size)
        chat.containerLayoutUpdated(layout, transition: .immediate)
        self.preparedChat = (peer.id, chat)
        ConceptsTopicSwipeAutopilot.mark("chatPrepared")
    }

    /// Автопилот: чат, который откроют из списка, собирается заранее (пока список листается) — собранный
    /// перед самым открытием догружал сообщения уже на экране, и раскрытие застывало на ≈0,24 с.
    func prepareChat(peerId: EnginePeer.Id) {
        if let candidate = self.candidates.first(where: { $0.peer.id == peerId }) {
            self.prepareChat(for: candidate.peer)
        }
    }

    func prewarmPreview(peerId: EnginePeer.Id) {
        self.panel?.prewarmPreview(peerId: peerId)
    }

    func prepareListOpen(peerId: EnginePeer.Id) {
        self.panel?.prepareListOpen(peerId: peerId)
    }

    private func dropPreparedPanel() {
        self.preparedPanel?.removeFromSuperview()
        self.preparedPanel = nil
    }

    private func beginTracking(control: UIView) {
        guard let chatNode = self.chatNode else {
            return
        }
        let m0 = CACurrentMediaTime()
        let wasPrepared = self.preparedPanel != nil
        self.preparePanelIfNeeded()
        guard let panel = self.preparedPanel else {
            return
        }
        let m1 = CACurrentMediaTime()
        self.preparedPanel = nil
        self.state = .tracking
        self.markedBelowThreshold = false
        self.trackStart = self.finger ?? CGPoint(x: chatNode.bounds.width / 2.0, y: chatNode.bounds.height - 120.0)
        self.selectionFeedback.prepare()
        let m2 = CACurrentMediaTime()
        chatNode.view.bringSubviewToFront(panel)
        panel.isHidden = false
        panel.alpha = 1.0
        self.panel = panel
        let m3 = CACurrentMediaTime()
        panel.animateIn(control: control)
        let m4 = CACurrentMediaTime()
        ConceptsTopicSwipeAutopilot.mark("rowShown|\(Int(self.trackStart.x))|\(Int(self.trackStart.y))")
        self.watchWallpapers(panel: panel)
        // v43: замер запуска панели по частям, мс: сборка (1 — была готова), вибрация, показ, появление, обои.
        let ms = { (a: Double, b: Double) in Int((b - a) * 1000.0) }
        ConceptsTopicSwipeAutopilot.mark("trackMs|\(wasPrepared ? 1 : 0)|\(ms(m0, m1))|\(ms(m1, m2))|\(ms(m2, m3))|\(ms(m3, m4))|\(ms(m4, CACurrentMediaTime()))")
    }

    /// v27: пока панель на экране, чаты концепта (этот, превью, собранный заранее) отвязаны от общей фазы обоев;
    /// первые 3 с фаза фона пишется в журнал записи.
    private func watchWallpapers(panel: ConceptsTopicSwipePanel) {
        let start = CACurrentMediaTime()
        var last = ""
        func tick() {
            guard let chatNode = self.chatNode, self.panel === panel else {
                return
            }
            var nodes: [ChatControllerNode] = [chatNode]
            nodes.append(contentsOf: panel.previewChatNodes)
            if let prepared = (self.preparedChat?.chat as? ChatControllerImpl)?.chatDisplayNode {
                nodes.append(prepared)
            }
            for node in nodes {
                ConceptsTopicSwipeWallpaper.detach(node)
            }
            let elapsed = CACurrentMediaTime() - start
            if elapsed < 3.0 {
                let state = "\(ConceptsTopicSwipeWallpaper.state(chatNode))|\(ConceptsTopicSwipeWallpaper.state(panel.currentPreviewChatNode))"
                if state != last {
                    last = state
                    ConceptsTopicSwipeAutopilot.mark("wp|\(state)")
                }
            }
            Queue.mainQueue().after(elapsed < 3.0 ? 1.0 / 60.0 : 0.1, tick)
        }
        tick()
    }

    private func cancelTracking() {
        self.state = .idle
        self.panel?.animateOut(completion: {})
        self.panel = nil
        self.preparedChat = nil
        self.controlHiddenUntil = .greatestFiniteMagnitude
    }

    private var pendingLanding: (() -> Void)?

    func deferLanding(_ land: @escaping () -> Void) -> Bool {
        guard self.state == .pinned || self.state == .opening else {
            return false
        }
        self.pendingLanding = land
        return true
    }

    private func runPendingLanding() {
        let land = self.pendingLanding
        self.pendingLanding = nil
        land?()
    }

    private func dismiss() {
        guard self.state == .pinned else {
            return
        }
        self.runPendingLanding()
        self.state = .idle
        self.panel?.animateOut(completion: {})
        self.panel = nil
        self.preparedChat = nil
        self.candidatesTimestamp = 0.0
    }

    private func fingerMoved(_ point: CGPoint) {
        self.finger = point
        // v19: ведение пальцем по ряду при удержании убрано — ряд листается после отпускания (свайп по аватаркам).
        guard self.state == .tracking, ConceptsTopicSwipeSession.scrubsWhilePulling, let panel = self.panel else {
            return
        }
        // v15: палец показывает на аватарку — вправо дальше по чатам (правые аватарки), влево — к значку «Все новые».
        let maxRow = panel.rowCount - 1
        // v17: справа много аватарок — на чат хватает 38 pt пальца (было 56, шаг ряда): переключение быстрее.
        let step = ConceptsTopicSwipePanel.trackPitch
        let position = CGFloat(panel.firstChatRow) + (point.x - self.trackStart.x) / step
        let current = CGFloat(panel.selectedRow)
        // v16: переключение на середине шага (было 0,62 — чат менялся с запаздыванием от пальца).
        if abs(position - current) > 0.52 {
            let row = max(0, min(maxRow, Int(position.rounded())))
            if row != panel.selectedRow {
                panel.select(row: row, fromUser: true)
            }
        }
    }

    // MARK: Открытие

    private func open(candidate: Candidate? = nil) {
        guard self.state == .tracking || self.state == .pinned, let panel = self.panel, let chatNode = self.chatNode, let controller = self.chatController(), let navigationController = controller.effectiveNavigationController else {
            return
        }
        guard let target = candidate ?? panel.selectedCandidate else {
            return
        }
        self.state = .opening
        self.impactFeedback.impactOccurred()

        let peer = target.peer
        let context = self.context
        // Панель переезжает в окно поверх навигации: настоящий чат собирается под раскрывающейся карточкой, и после
        // раскрытия карточка сразу гаснет — без остановки кадра на сборку чата (раньше ≈0,2 с стоял неподвижный кадр).
        if let window = chatNode.view.window {
            let frame = chatNode.view.convert(panel.frame, to: window)
            window.addSubview(panel)
            panel.frame = frame
        }
        self.panel = nil
        // Новый чат кладётся поверх текущего: «назад» возвращает в чат, из которого тянули.
        // В ролике чаты остаются непрочитанными, чтобы последний кадр совпал с первым (счётчик на «назад», ряд).
        let chat: ChatController
        if let prepared = self.preparedChat, prepared.peerId == peer.id {
            chat = prepared.chat
            ConceptsTopicSwipeAutopilot.mark("chatReused")
        } else {
            chat = context.sharedContext.makeChatController(context: context, chatLocation: .peer(id: peer.id), subject: nil, botStart: nil, mode: .standard(.default), params: nil)
            if ConceptsTopicSwipeAutopilot.isRecording {
                chat.canReadHistory.set(false)
            }
        }
        self.preparedChat = nil
        let previewAtEnd = ConceptsTopicSwipeSession.isAtEnd(panel.previewController)
        // v22: сообщения предпросмотра доезжают туда, где они стоят в настоящем чате, ещё в карточке — вместе с раскрытием.
        // Было: подмена, затем сдвиг настоящего чата на ≈8 pt за 0,25 с — контент «отскакивал» после остановки.
        var preAligned = false
        var alignEnd: Double = 0.0
        func preAlign(spring: Bool) -> Bool {
            guard let chatImpl = chat as? ChatControllerImpl, chatImpl.isNodeLoaded, let previewImpl = panel.previewController as? ChatControllerImpl, previewImpl.isNodeLoaded else {
                return false
            }
            let real = ConceptsTopicSwipeSession.messageAnchors(chatImpl)
            let preview = ConceptsTopicSwipeSession.messageAnchors(previewImpl)
            guard let id = real.keys.sorted().first(where: { preview[$0] != nil }), let realY = real[id], let previewY = preview[id] else {
                return false
            }
            let delta = realY - previewY
            ConceptsTopicSwipeAutopilot.mark("preAlign|\(Int(delta))|\(spring ? 1 : 0)")
            // Собранный заранее, но ещё не показанный чат может стоять на другой прокрутке (он встаёт на «Непрочитанные»
            // уже в окне): большой разрыв — не выравниваем сейчас, сверим после подмены.
            guard abs(delta) <= 40.0 else {
                return false
            }
            preAligned = true
            guard abs(delta) > 0.5 else {
                return true
            }
            let animation: CABasicAnimation
            if spring {
                let springAnimation = CASpringAnimation(keyPath: "transform.translation.y")
                springAnimation.mass = 1.0
                springAnimation.stiffness = 440.0
                springAnimation.damping = 42.0
                springAnimation.duration = springAnimation.settlingDuration
                animation = springAnimation
            } else {
                animation = CABasicAnimation(keyPath: "transform.translation.y")
                animation.duration = 0.25
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.0, 0.4, 0.0, 1.0)
            }
            animation.fromValue = 0.0
            animation.toValue = delta
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            previewImpl.chatDisplayNode.historyNodeContainer.layer.add(animation, forKey: "conceptsTopicSwipePreAlign")
            alignEnd = CACurrentMediaTime() + (spring ? 0.3 : 0.25)
            return true
        }
        // Нижний отступ предпросмотра — по нижней панели настоящего чата (у канала «Mute» ниже поля ввода): иначе
        // сообщения в карточке и в чате стояли на ≈8 pt по-разному.
        var targetBottomInset: CGFloat?
        if let chatImpl = chat as? ChatControllerImpl, chatImpl.isNodeLoaded {
            let node = chatImpl.chatDisplayNode
            let inset = node.bounds.height - node.inputPanelBackgroundNode.frame.minY
            if node.bounds.height > 0.0, !node.inputPanelBackgroundNode.frame.isEmpty, inset > 0.0, inset < node.bounds.height / 2.0 {
                targetBottomInset = inset
            }
        }
        ConceptsTopicSwipeAutopilot.mark("targetInset|\(Int(targetBottomInset ?? -1))")
        panel.animateZoomOpen(peer: peer, bottomInset: targetBottomInset, completion: { [weak self, weak panel] in
            guard let panel else {
                return
            }
            // Карточка гаснет, только когда настоящий чат под ней дорисован: его сообщения при первом показе сами
            // проявляются, и угасание поверх них давало «мигание» — весь экран на ≈0,2 с становился полупрозрачным.
            let started = CACurrentMediaTime()
            func isSettled() -> Bool {
                guard let chatImpl = chat as? ChatControllerImpl, chatImpl.isNodeLoaded else {
                    return false
                }
                var count = 0
                var animating = false
                chatImpl.chatDisplayNode.historyNode.forEachVisibleItemNode { node in
                    count += 1
                    if node.alpha < 0.99 || !(node.layer.animationKeys() ?? []).isEmpty {
                        animating = true
                    }
                }
                // Весь список сообщений при первой загрузке проявляется целиком (прозрачность 0 → 1): ждём и его.
                var layer: CALayer? = chatImpl.chatDisplayNode.historyNode.layer
                while let current = layer, current !== chatImpl.view.layer {
                    if current.opacity < 0.99 || (current.animationKeys() ?? []).contains(where: { $0.contains("opacity") }) {
                        animating = true
                    }
                    layer = current.superlayer
                }
                return count > 0 && !animating
            }
            var isReady = false
            let readyDisposable = (chat.ready.get() |> filter { $0 } |> take(1) |> deliverOnMainQueue).startStandalone(next: { _ in
                isReady = true
            })
            var settledAt: Double?
            var scrolledToEnd = false
            func poll() {
                // Настоящий чат открывается на «Непрочитанных» вверху экрана, а у короткого канала под ними оставалась пустота
                // (и родная плашка «следующий канал»). v18: если в предпросмотре новые поместились и он стоит в конце переписки —
                // настоящий чат ставится так же (без анимации, под карточкой); не поместились — оба стоят на «Непрочитанных».
                if previewAtEnd, isReady, !scrolledToEnd, !preAligned, let chatImpl = chat as? ChatControllerImpl, chatImpl.isNodeLoaded {
                    scrolledToEnd = true
                    ConceptsTopicSwipeSession.scrollToEnd(chatImpl)
                    Queue.mainQueue().after(1.0 / 60.0, poll)
                    return
                }
                // Готов (история загружена) и дорисован: ещё 3 кадра на асинхронную отрисовку пузырей сообщений.
                if settledAt == nil && isReady && isSettled() {
                    settledAt = CACurrentMediaTime()
                    // Не выровняли при старте раскрытия (чат ещё собирался) — выравниваем предпросмотр сейчас, до подмены.
                    if !preAligned {
                        let _ = preAlign(spring: false)
                    }
                    if let chatImpl = chat as? ChatControllerImpl {
                        let syncStart = CACurrentMediaTime()
                        ConceptsTopicSwipeSession.syncStickers(from: panel.previewController, to: chatImpl)
                        ConceptsTopicSwipeAutopilot.mark("syncMs|\(Int((CACurrentMediaTime() - syncStart) * 1000.0))")
                    }
                }
                if let settledAt, CACurrentMediaTime() - settledAt >= 0.05, CACurrentMediaTime() >= alignEnd {
                    readyDisposable.dispose()
                    ConceptsTopicSwipeAutopilot.mark("openWait|\(Int((CACurrentMediaTime() - started) * 1000))")
                    finish()
                } else if CACurrentMediaTime() - started > 0.8 {
                    readyDisposable.dispose()
                    ConceptsTopicSwipeAutopilot.mark("openWait|\(Int((CACurrentMediaTime() - started) * 1000))")
                    finish()
                } else {
                    Queue.mainQueue().after(1.0 / 60.0, poll)
                }
            }
            func finish() {
            // Настоящий чат стоит на другой прокрутке, чем предпросмотр: сообщения стартуют там, где были в карточке,
            // и доезжают на место, пока карточка гаснет — без «двоения».
            let previewAnchors = ConceptsTopicSwipeSession.messageAnchors(panel.previewController)
            if let chatImpl = chat as? ChatControllerImpl {
                let realAnchors = ConceptsTopicSwipeSession.messageAnchors(chatImpl)
                if !preAligned, let id = realAnchors.keys.first(where: { previewAnchors[$0] != nil }), let real = realAnchors[id], let preview = previewAnchors[id], abs(preview - real) > 0.5 {
                    let animation = CABasicAnimation(keyPath: "position")
                    animation.fromValue = NSValue(cgPoint: CGPoint(x: 0.0, y: preview - real))
                    animation.toValue = NSValue(cgPoint: .zero)
                    animation.isAdditive = true
                    // v17: короче (0,45 → 0,25 с): у последнего открытия сдвиг ещё шёл в конце ролика и петля не сходилась.
                    animation.duration = 0.25
                    ConceptsTopicSwipeAutopilot.mark("align|\(Int(preview - real))")
                    animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.0, 0.4, 0.0, 1.0)
                    chatImpl.chatDisplayNode.historyNodeContainer.layer.add(animation, forKey: "conceptsTopicSwipeAlign")
                }
            }
            panel.prepareForFadeOut()
            // Под карточкой настоящий чат уже стоит так же (сообщения выровнены): карточка остаётся только полосой шапки,
            // и плавно сменяется лишь шапка (в настоящей есть «назад» и аватарка). Угасание всей карточки поверх
            // такого же чата давало «мигание» — экран на ≈0,2 с становился полупрозрачным.
            if let navigationBar = chat.navigationBar?.view, let window = panel.window {
                let headerBottom = navigationBar.convert(navigationBar.bounds, to: window).maxY
                let mask = CALayer()
                mask.backgroundColor = UIColor.black.cgColor
                mask.frame = CGRect(x: 0.0, y: 0.0, width: panel.bounds.width, height: max(0.0, window.convert(CGPoint(x: 0.0, y: headerBottom), to: panel).y))
                panel.layer.mask = mask
                // Полоса шапки карточки уходит под настоящую шапку: её стекло, закрытое карточкой, не рисовалось и
                // проявлялось только после угасания карточки — подпись «мигала». Теперь оно проявляется поверх такой же шапки.
                if let container = navigationBar.superview {
                    let frame = panel.convert(panel.bounds, to: container)
                    container.insertSubview(panel, belowSubview: navigationBar)
                    panel.frame = frame
                }
            }
            // Настоящая шапка после подмены ещё дорисовывается сама (≈0,25 с): полоса шапки карточки держится, пока
            // у шапки под ней идут анимации, затем гаснет — подписи совпадают, ожидание не видно.
            let headerStarted = CACurrentMediaTime()
            func headerAnimating(_ layer: CALayer, _ depth: Int) -> Bool {
                if !(layer.animationKeys() ?? []).isEmpty || layer.opacity < 0.99 && layer.opacity > 0.01 {
                    return true
                }
                if depth < 9 {
                    for sublayer in layer.sublayers ?? [] where !sublayer.isHidden && sublayer.opacity > 0.01 {
                        if headerAnimating(sublayer, depth + 1) {
                            return true
                        }
                    }
                }
                return false
            }
            func fadeHeader() {
                // v29: не дольше 0,25 с (было 0,5 — ожидание всегда шло до упора, и полоса карточки висела во время второго вытягивания).
                if let navigationBar = chat.navigationBar?.view, headerAnimating(navigationBar.layer, 0), CACurrentMediaTime() - headerStarted < ConceptsTopicSwipeTune.v("headerMax", 0.25) {
                    Queue.mainQueue().after(1.0 / 60.0, fadeHeader)
                    return
                }
                ConceptsTopicSwipeAutopilot.mark("headerWait|\(Int((CACurrentMediaTime() - headerStarted) * 1000))")
                // «Назад» и аватарка уже видны (проявились при раскрытии); подпись настоящей шапки проявляется поверх
                // такой же подписи полосы карточки, затем полоса убирается.
                let title = (chat as? ChatControllerImpl)?.chatTitleView
                ConceptsTopicSwipeMotion.standard(0.15, {
                    title?.alpha = 1.0
                })
                Queue.mainQueue().after(0.17, {
                    panel.removeFromSuperview()
                })
            }
            fadeHeader()
            ConceptsTopicSwipeClock.chatOpenedAt = CACurrentMediaTime()
            ConceptsTopicSwipeAutopilot.mark("chatOpened")
            // Чат, из которого тянули, закрыт открытым поверх — посадка оттягивания уже не видна.
            self?.runPendingLanding()
            }
            poll()
        })
        // Чат подставляется сразу, как только раскрытие запущено (оно идёт вне главного потока и сборкой чата не тормозится):
        // его сообщения дорисовываются ≈0,5 с, и к угасанию карточки он должен быть готов, иначе карточка гасла над пустыми обоями.
        Queue.mainQueue().after(0.03, { [weak panel] in
            let pushStart = CACurrentMediaTime()
            navigationController.pushViewController(chat, animated: false)
            ConceptsTopicSwipeAutopilot.mark("pushMs|\(Int((CACurrentMediaTime() - pushStart) * 1000.0))")
            // Замер: длинные кадры главного потока во время раскрытия (метка frameGap).
            var lastTick = CACurrentMediaTime()
            let gapEnd = lastTick + 0.6
            func watchGaps() {
                let now = CACurrentMediaTime()
                if now - lastTick > 0.04 {
                    ConceptsTopicSwipeAutopilot.mark("frameGap|\(Int((now - lastTick) * 1000.0))")
                }
                lastTick = now
                if now < gapEnd {
                    DispatchQueue.main.async(execute: watchGaps)
                }
            }
            DispatchQueue.main.async(execute: watchGaps)
            // v20: кнопки настоящего чата («назад», аватарка, нижняя панель) проявляются уже во время раскрытия.
            // Чат встаёт в окно, когда готов (собранный заранее — сразу); панель переезжает в него на 0,15 с раскрытия.
            let pushed = CACurrentMediaTime()
            func embedPanel() {
                guard let panel, let chatImpl = chat as? ChatControllerImpl else {
                    return
                }
                if chatImpl.isNodeLoaded, chatImpl.view.window != nil, CACurrentMediaTime() - pushed >= panel.embedDelay {
                    ConceptsTopicSwipeAutopilot.mark("embedAt|\(Int((CACurrentMediaTime() - pushed) * 1000))")
                    panel.embed(in: chatImpl)
                } else if CACurrentMediaTime() - pushed < panel.embedDelay + 0.13 {
                    Queue.mainQueue().after(1.0 / 60.0, embedPanel)
                }
            }
            embedPanel()
            // v22: как только настоящий чат встал в окно на своё место, сообщения карточки доезжают к нему той же пружиной,
            // что и раскрытие, — ещё на ходу. Собранный вне окна чат стоит на другой прокрутке: сверяем только в окне.
            func alignWhileOpening() {
                guard !preAligned, CACurrentMediaTime() - pushed < 0.45 else {
                    return
                }
                if let chatImpl = chat as? ChatControllerImpl, chatImpl.isNodeLoaded, chatImpl.view.window != nil, !previewAtEnd || ConceptsTopicSwipeSession.isAtEnd(chatImpl), preAlign(spring: true) {
                    return
                }
                Queue.mainQueue().after(1.0 / 60.0, alignWhileOpening)
            }
            alignWhileOpening()
        })
        // Пока чат раскрыт поверх, отпускание пальца родное «открыть следующий» не запускает; когда вернутся назад —
        // жест снова работает с начала.
        Queue.mainQueue().after(1.0, { [weak self] in
            guard let self, self.state == .opening else {
                return
            }
            self.state = .idle
            self.candidatesTimestamp = 0.0
            self.control?.alpha = 1.0
        })
    }

    // MARK: Вспомогательное

    static let scrubsWhilePulling = false

    /// Виден ли в чате последний загруженный пузырь (чат стоит в конце переписки).
    static func isAtEnd(_ controller: ChatController?) -> Bool {
        guard let chat = controller as? ChatControllerImpl, chat.isNodeLoaded else {
            return false
        }
        var last: MessageIndex?
        chat.chatDisplayNode.historyNode.forEachItemNode { node in
            if let itemNode = node as? ChatMessageItemView, let item = itemNode.item, last == nil || item.message.index > last! {
                last = item.message.index
            }
        }
        var visible = false
        chat.chatDisplayNode.historyNode.forEachVisibleItemNode { node in
            if let itemNode = node as? ChatMessageItemView, let item = itemNode.item, item.message.index == last {
                visible = true
            }
        }
        return visible
    }

    /// Без анимации — к последнему сообщению у нижнего края (список чата перевёрнут: `.top` — визуальный низ).

    static func scrollToEnd(_ chat: ChatControllerImpl, animated: Bool = false) {
        var last: MessageIndex?
        chat.chatDisplayNode.historyNode.forEachItemNode { node in
            if let itemNode = node as? ChatMessageItemView, let item = itemNode.item {
                let index = item.message.index
                if last == nil || index > last! {
                    last = index
                }
            }
        }
        if let last {
            chat.chatDisplayNode.historyNode.scrollToMessage(from: last, to: last, animated: animated, highlight: false, scrollPosition: .top(0.0))
        }
    }

    /// v23: анимированные стикеры настоящего чата продолжают с того же кадра, что и в карточке (было: при подмене
    /// стикер начинался заново).
    static func syncStickers(from preview: ChatController?, to chat: ChatControllerImpl) {
        guard let preview = preview as? ChatControllerImpl, preview.isNodeLoaded else {
            return
        }
        var frames: [MessageId: (Int, Int)] = [:]
        preview.chatDisplayNode.historyNode.forEachItemNode { node in
            if let itemNode = node as? ChatMessageAnimatedStickerItemNode, let item = itemNode.item, let animation = itemNode.animationNode as? AnimatedStickerNode, animation.currentFrameCount > 0 {
                frames[item.message.id] = (animation.currentFrameIndex, animation.currentFrameCount)
            }
        }
        chat.chatDisplayNode.historyNode.forEachItemNode { node in
            if let itemNode = node as? ChatMessageAnimatedStickerItemNode, let item = itemNode.item, let animation = itemNode.animationNode as? AnimatedStickerNode, let (index, count) = frames[item.message.id] {
                // Кадр уходит в очередь отрисовки — следующий за текущим, чтобы не отстать на кадр.
                animation.play(firstFrame: false, fromIndex: (index + 1) % max(1, count))
                ConceptsTopicSwipeAutopilot.mark("stickerSync|\(index)|\(count)")
            }
        }
    }

    /// Положение сообщений на экране (верх ячейки в координатах окна) — для выравнивания предпросмотра и настоящего чата.
    static func messageAnchors(_ controller: ChatController?) -> [MessageId: CGFloat] {
        var result: [MessageId: CGFloat] = [:]
        guard let controller = controller as? ChatControllerImpl else {
            return result
        }
        controller.chatDisplayNode.historyNode.forEachItemNode { node in
            if let itemNode = node as? ChatMessageItemView, let item = itemNode.item {
                result[item.message.id] = node.view.convert(node.bounds, to: nil).midY
            }
        }
        return result
    }

    private func chatController() -> ChatControllerImpl? {
        var responder: UIResponder? = self.chatNode?.view
        while let current = responder {
            if let controller = current as? ChatControllerImpl {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    private func fallbackLayout(size: CGSize) -> ContainerViewLayout {
        return ContainerViewLayout(size: size, metrics: LayoutMetrics(widthClass: .compact, heightClass: .compact, orientation: nil), deviceMetrics: .iPhone16Pro, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), reservedCorners: .none, division: nil, additionalInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
    }
}

// MARK: - Строка чата: карточка в стопке или строка списка

private final class ConceptsTopicSwipeRowView: UIView {
    let candidate: ConceptsTopicSwipeSession.Candidate
    private let isCard: Bool
    private let blurView: UIVisualEffectView?
    private let fillView = UIView()
    private let avatar: AvatarNode
    private let titleLabel = UILabel()
    private let snippetLabel = UILabel()
    private let badge = UILabel()
    private let separator = UIView()
    private let timeLabel = UILabel()
    private let authorLabel = UILabel()
    private let thumbView = UIImageView()
    private let highlightColor: UIColor

    init(context: AccountContext, theme: PresentationTheme, candidate: ConceptsTopicSwipeSession.Candidate, isCard: Bool) {
        self.candidate = candidate
        self.highlightColor = theme.chatList.itemHighlightedBackgroundColor
        self.isCard = isCard
        self.avatar = AvatarNode(font: avatarPlaceholderFont(size: 15.0))
        if isCard {
            self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: theme.overallDarkAppearance ? .systemThinMaterialDark : .systemThinMaterialLight))
        } else {
            self.blurView = nil
        }
        super.init(frame: .zero)

        if let blurView = self.blurView {
            blurView.clipsToBounds = true
            blurView.layer.cornerRadius = 18.0
            if #available(iOS 13.0, *) {
                blurView.layer.cornerCurve = .continuous
            }
            self.addSubview(blurView)
            self.fillView.clipsToBounds = true
            self.fillView.layer.cornerRadius = 18.0
            if #available(iOS 13.0, *) {
                self.fillView.layer.cornerCurve = .continuous
            }
            self.fillView.backgroundColor = theme.chatList.itemBackgroundColor
            self.fillView.alpha = 0.0
            self.addSubview(self.fillView)
            self.layer.shadowColor = UIColor.black.cgColor
            self.layer.shadowRadius = 10.0
            self.layer.shadowOffset = CGSize(width: 0.0, height: 3.0)
            self.layer.shadowOpacity = 0.0
        } else {
            self.separator.backgroundColor = theme.chatList.itemSeparatorColor
            self.addSubview(self.separator)
        }

        let avatarSize: CGFloat = isCard ? 38.0 : 60.0
        self.avatar.setPeer(context: context, theme: theme, peer: candidate.peer, synchronousLoad: true, displayDimensions: CGSize(width: avatarSize, height: avatarSize))
        self.addSubview(self.avatar.view)

        // Шрифты родной строки списка чатов: заголовок 16 medium, текст 15.
        self.titleLabel.font = UIFont.systemFont(ofSize: isCard ? 15.0 : 16.0, weight: isCard ? .semibold : .medium)
        self.titleLabel.textColor = theme.chatList.titleColor
        self.titleLabel.text = candidate.peer.compactDisplayTitle
        self.addSubview(self.titleLabel)

        self.snippetLabel.font = UIFont.systemFont(ofSize: isCard ? 13.0 : 15.0)
        self.snippetLabel.textColor = theme.chatList.messageTextColor
        self.snippetLabel.text = candidate.snippet
        self.snippetLabel.numberOfLines = isCard ? 1 : 2
        self.addSubview(self.snippetLabel)

        self.badge.font = UIFont.systemFont(ofSize: 12.0, weight: .semibold)
        self.badge.textAlignment = .center
        self.badge.clipsToBounds = true
        self.badge.layer.cornerRadius = 10.0
        self.badge.text = "\(candidate.unreadCount)"
        self.badge.textColor = candidate.isMuted ? theme.chatList.unreadBadgeInactiveTextColor : theme.chatList.unreadBadgeActiveTextColor
        self.badge.backgroundColor = candidate.isMuted ? theme.chatList.unreadBadgeInactiveBackgroundColor : theme.chatList.unreadBadgeActiveBackgroundColor
        self.addSubview(self.badge)

        if !isCard {
            // Как в родной строке списка чатов: время справа от имени, автор сообщения в группе отдельной строкой,
            // миниатюра фото перед текстом.
            if candidate.timestamp != 0 {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                self.timeLabel.text = formatter.string(from: Date(timeIntervalSince1970: Double(candidate.timestamp)))
            }
            self.timeLabel.font = UIFont.systemFont(ofSize: 14.0)
            self.timeLabel.textColor = theme.chatList.dateTextColor
            self.addSubview(self.timeLabel)
            if let author = candidate.author {
                self.authorLabel.text = author
                self.authorLabel.font = UIFont.systemFont(ofSize: 15.0)
                self.authorLabel.textColor = theme.chatList.authorNameColor
                self.addSubview(self.authorLabel)
                self.snippetLabel.numberOfLines = 1
            }
            if let thumbnail = candidate.thumbnail {
                self.thumbView.image = thumbnail
                self.thumbView.contentMode = .scaleAspectFill
                self.thumbView.clipsToBounds = true
                self.thumbView.layer.cornerRadius = 3.0
                self.addSubview(self.thumbView)
                self.snippetLabel.numberOfLines = 1
            }
        }
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.blurView?.frame = self.bounds
        self.fillView.frame = self.bounds
        if self.isCard {
            self.layer.shadowPath = UIBezierPath(roundedRect: self.bounds, cornerRadius: 18.0).cgPath
        }
        let avatarSize: CGFloat = self.isCard ? 38.0 : 60.0
        let inset: CGFloat = self.isCard ? 12.0 : 10.0
        self.avatar.frame = CGRect(x: inset, y: floor((size.height - avatarSize) / 2.0), width: avatarSize, height: avatarSize)
        let badgeWidth = max(20.0, ceil(self.badge.sizeThatFits(CGSize(width: 100.0, height: 20.0)).width) + 10.0)
        let textX = inset + avatarSize + 10.0
        let titleHeight = ceil(self.titleLabel.font.lineHeight)
        let snippetHeight = ceil(self.snippetLabel.font.lineHeight)
        if self.isCard {
            self.badge.frame = CGRect(x: size.width - inset - badgeWidth, y: floor((size.height - 20.0) / 2.0), width: badgeWidth, height: 20.0)
            let textWidth = max(0.0, self.badge.frame.minX - 8.0 - textX)
            let top = floor((size.height - titleHeight - 1.0 - snippetHeight) / 2.0)
            self.titleLabel.frame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight)
            self.snippetLabel.frame = CGRect(x: textX, y: top + titleHeight + 1.0, width: textWidth, height: snippetHeight)
        } else {
            // Раскладка родной строки списка чатов (76 pt): имя сверху, текст до двух строк, счётчик справа внизу.
            self.badge.frame = CGRect(x: size.width - 16.0 - badgeWidth, y: size.height - 14.0 - 20.0, width: badgeWidth, height: 20.0)
            let timeWidth = ceil(self.timeLabel.sizeThatFits(CGSize(width: 120.0, height: 20.0)).width)
            self.timeLabel.frame = CGRect(x: size.width - 16.0 - timeWidth, y: 9.0, width: timeWidth, height: titleHeight)
            self.titleLabel.frame = CGRect(x: textX, y: 8.0, width: max(0.0, self.timeLabel.frame.minX - 6.0 - textX), height: titleHeight)
            let snippetWidth = max(0.0, self.badge.frame.minX - 8.0 - textX)
            var lineY = 8.0 + titleHeight + 1.0
            if self.authorLabel.superview != nil {
                self.authorLabel.frame = CGRect(x: textX, y: lineY, width: snippetWidth, height: snippetHeight)
                lineY += snippetHeight
            }
            var snippetX = textX
            if self.thumbView.superview != nil {
                self.thumbView.frame = CGRect(x: textX, y: lineY + floor((snippetHeight - 20.0) / 2.0), width: 20.0, height: 20.0)
                snippetX += 26.0
            }
            let lines: CGFloat = self.snippetLabel.numberOfLines == 1 ? 1.0 : 2.0
            let snippetSize = self.snippetLabel.sizeThatFits(CGSize(width: snippetWidth - (snippetX - textX), height: snippetHeight * lines + 2.0))
            self.snippetLabel.frame = CGRect(x: snippetX, y: lineY, width: snippetWidth - (snippetX - textX), height: min(snippetHeight * lines + 2.0, ceil(snippetSize.height)))
        }
        self.separator.frame = CGRect(x: textX, y: size.height - 0.5, width: max(0.0, size.width - textX), height: 0.5)
    }

    /// Подсветка нажатой строки — цвет родного списка чатов.
    func setHighlighted(_ highlighted: Bool) {
        // Короткое проявление подсветки (0,15 с) — нажатие читается, а кадр не «застывает» до отпускания.
        let color = highlighted ? self.highlightColor : .clear
        ConceptsTopicSwipeMotion.ease(0.15, { self.backgroundColor = color })
    }

    /// Выбранная карточка: светлая подложка, лёгкое увеличение и тень.
    func setSelected(_ selected: Bool, animated: Bool) {
        guard self.isCard else {
            return
        }
        let changes: () -> Void = {
            self.fillView.alpha = selected ? 1.0 : 0.0
            self.transform = selected ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
            self.layer.shadowOpacity = selected ? 0.22 : 0.0
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0.0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }
}

// MARK: - Аватарка в ряду: чат или значок «Все новые»

private final class ConceptsTopicSwipeAvatarItem: UIView {
    /// Стеклянный круг 66 pt, аватарка 60 с отступом 3 — как аватарка на стекле в шапке чата (44 и 3).
    static let size: CGFloat = 66.0
    static let inset: CGFloat = 3.0

    let candidate: ConceptsTopicSwipeSession.Candidate?
    private let glass = GlassBackgroundView()
    private let avatar: AvatarNode?
    private let glyph = UIImageView()
    private let badge = UILabel()
    private let badgeGlass = GlassBackgroundView()

    init(context: AccountContext, theme: PresentationTheme, candidate: ConceptsTopicSwipeSession.Candidate?, listCount: Int = 0) {
        self.candidate = candidate
        let size = ConceptsTopicSwipeAvatarItem.size
        let inset = ConceptsTopicSwipeAvatarItem.inset
        if candidate != nil {
            self.avatar = AvatarNode(font: avatarPlaceholderFont(size: 24.0))
        } else {
            self.avatar = nil
        }
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: size, height: size))

        // Каждая аватарка и значок «Все новые» — на своём стекле (токен фона контекстного меню и кнопок шапки: .panel).
        self.glass.isUserInteractionEnabled = false
        self.glass.frame = self.bounds
        // v34: значок «Все новые» снова на стекле панели, как чаты: синяя иконка и счётчик чатов (v18 — синее стекло).
        self.glass.update(size: self.bounds.size, cornerRadius: size / 2.0, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), transition: .immediate)
        self.addSubview(self.glass)

        if let candidate, let avatar = self.avatar {
            let avatarSize = size - inset * 2.0
            avatar.setPeer(context: context, theme: theme, peer: candidate.peer, synchronousLoad: true, displayDimensions: CGSize(width: avatarSize, height: avatarSize))
            avatar.frame = self.bounds.insetBy(dx: inset, dy: inset)
            self.addSubview(avatar.view)

            // v17: счётчик — стеклянная капсула, как у аватарки в родном доскролле (белый текст 13 pt, высота текст + 4,
            // вырез 2 pt в аватарке); без белой обводки. v18: стекло синее (у выключенных уведомлений — серое), как счётчики списка.
            self.addBadge(text: "\(candidate.unreadCount)", color: candidate.isMuted ? theme.chatList.unreadBadgeInactiveBackgroundColor : theme.chatList.unreadBadgeActiveBackgroundColor)

            // v19: без выреза в аватарке под счётчиком (маска давала артефакт при масштабе).
        } else {
            // v37: контурная иконка «Чаты» из родного контекстного меню (была залитая иконка вкладки).
            self.glyph.image = UIImage(bundleImageName: ConceptsTopicSwipeTune.v("outlineGlyph", 1.0) > 0.5 ? "Chat/Context Menu/Chats" : "Chat List/Tabs/IconChats")?.withRenderingMode(.alwaysTemplate)
            // v36: иконка — основной цвет текста (чёрный), счётчик остаётся синим.
            self.glyph.tintColor = theme.list.itemPrimaryTextColor
            self.glyph.contentMode = .center
            self.glyph.frame = self.bounds
            // v37: контурная иконка меню рассчитана на 24 pt — в круге 66 крупнее (glyphSize), линия толще.
            let glyphSize = CGFloat(ConceptsTopicSwipeTune.v("glyphSize", 0.0))
            if glyphSize > 0.0 {
                self.glyph.contentMode = .scaleAspectFit
                self.glyph.frame = CGRect(x: (size - glyphSize) / 2.0, y: (size - glyphSize) / 2.0, width: glyphSize, height: glyphSize)
            }
            self.addSubview(self.glyph)
            if listCount > 0 {
                self.addBadge(text: "\(listCount)", color: theme.chatList.unreadBadgeActiveBackgroundColor)
            }
        }
    }

    private func addBadge(text: String, color: UIColor) {
        let size = ConceptsTopicSwipeAvatarItem.size
        self.badge.font = Font.semibold(13.0)
        self.badge.textAlignment = .center
        self.badge.text = text
        self.badge.textColor = .white
        let textSize = self.badge.sizeThatFits(CGSize(width: 100.0, height: 30.0))
        let badgeHeight = ceil(textSize.height) + 4.0
        let badgeWidth = max(badgeHeight, ceil(textSize.width) + 9.0)
        let badgeFrame = CGRect(x: size - badgeWidth + 3.0, y: -3.0, width: badgeWidth, height: badgeHeight)
        self.badgeGlass.isUserInteractionEnabled = false
        self.badgeGlass.frame = badgeFrame
        self.badgeGlass.update(size: badgeFrame.size, cornerRadius: badgeHeight / 2.0, isDark: true, tintColor: .init(kind: .custom(style: .default, color: color)), transition: .immediate)
        self.badge.frame = CGRect(origin: .zero, size: badgeFrame.size)
        self.badgeGlass.contentView.addSubview(self.badge)
        self.addSubview(self.badgeGlass)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func setSelected(_ selected: Bool) {
    }

    /// v18: пока родная капсула «следующий чат» перетекает в эту аватарку, её стекло рисует общая капсула,
    /// а счётчик появляется после перетекания.
    func showBadge(duration: Double, delay: Double) {
        self.badgeGlass.alpha = 0.0
        ConceptsTopicSwipeMotion.standard(duration, delay: delay, {
            self.badgeGlass.alpha = 1.0
        })
    }

    func setMorphing(_ morphing: Bool, animated: Bool) {
        let alpha: CGFloat = morphing ? 0.0 : 1.0
        self.glass.alpha = alpha
        if animated {
            self.badgeGlass.alpha = 0.0
            self.badgeGlass.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            ConceptsTopicSwipeMotion.spring({
                self.badgeGlass.alpha = 1.0
                self.badgeGlass.transform = .identity
            })
        } else {
            self.badgeGlass.alpha = alpha
        }
    }
}

// MARK: - Панель: затемнение, предпросмотр (или список) сверху, стопка карточек снизу

/// Стеклянная капсула шапки карточки (как родная капсула заголовка чата: стекло, имя 17 pt, статус 12 pt, поля 14 pt).
/// Смена: капсула тянется под новый текст пружиной стекла, старый текст гаснет с размытием, новый проявляется из размытия.
private final class ConceptsTopicSwipeHeaderPill: UIView {
    static let height: CGFloat = 44.0
    static let bounce = ComponentTransition(animation: .curve(duration: 0.6, curve: .bounce(stiffness: 300.0, damping: 20.0)))
    private let theme: PresentationTheme
    private let glass = GlassBackgroundView()
    private var content: UIView?
    private var text = ""

    init(theme: PresentationTheme) {
        self.theme = theme
        super.init(frame: .zero)
        self.addSubview(self.glass)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    private func makeContent(title: String, subtitle: String, subtitleIsActive: Bool) -> UIView {
        let titleLabel = UILabel()
        titleLabel.font = Font.semibold(17.0)
        titleLabel.textColor = self.theme.chat.inputPanel.panelControlColor
        titleLabel.text = title
        titleLabel.sizeToFit()
        let subtitleLabel = UILabel()
        subtitleLabel.font = Font.regular(12.0)
        subtitleLabel.textColor = subtitleIsActive ? self.theme.rootController.navigationBar.accentTextColor : self.theme.chat.inputPanel.inputControlColor
        subtitleLabel.text = subtitle
        subtitleLabel.sizeToFit()
        let width = ceil(max(titleLabel.bounds.width, subtitleLabel.bounds.width))
        let view = UIView(frame: CGRect(x: 0.0, y: 0.0, width: width, height: ceil(titleLabel.bounds.height + subtitleLabel.bounds.height)))
        view.isUserInteractionEnabled = false
        titleLabel.frame.origin = CGPoint(x: floor((width - titleLabel.bounds.width) / 2.0), y: 0.0)
        subtitleLabel.frame.origin = CGPoint(x: floor((width - subtitleLabel.bounds.width) / 2.0), y: titleLabel.bounds.height)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        return view
    }

    private func apply(size: CGSize, center: CGPoint, transition: ComponentTransition, positionTransition: ComponentTransition? = nil) {
        (positionTransition ?? transition).setPosition(view: self, position: center)
        transition.setBounds(view: self, bounds: CGRect(origin: .zero, size: size))
        transition.setFrame(view: self.glass, frame: CGRect(origin: .zero, size: size))
        self.glass.update(size: size, cornerRadius: size.height / 2.0, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), transition: transition)
        if let content = self.content {
            transition.setPosition(view: content, position: CGPoint(x: size.width / 2.0, y: size.height / 2.0))
        }
    }

    func update(title: String, subtitle: String, subtitleIsActive: Bool, center: CGPoint, animated: Bool) {
        let key = title + "\n" + subtitle + (subtitleIsActive ? "\n1" : "")
        // v16: стекло тянется пружиной с отскоком, как капсула шапки при входе в чат (ζ ≈ 0,58).
        let transition: ComponentTransition = animated ? ConceptsTopicSwipeHeaderPill.bounce : .immediate
        if key == self.text, let content = self.content {
            self.apply(size: CGSize(width: content.bounds.width + 28.0, height: ConceptsTopicSwipeHeaderPill.height), center: center, transition: transition)
            return
        }
        self.text = key
        let incoming = self.makeContent(title: title, subtitle: subtitle, subtitleIsActive: subtitleIsActive)
        let outgoing = self.content
        self.content = incoming
        incoming.center = outgoing?.center ?? CGPoint(x: self.bounds.width / 2.0, y: self.bounds.height / 2.0)
        self.glass.contentView.addSubview(incoming)
        self.apply(size: CGSize(width: incoming.bounds.width + 28.0, height: ConceptsTopicSwipeHeaderPill.height), center: center, transition: transition)
        if let outgoing {
            if animated {
                let blur = ComponentTransition(animation: .curve(duration: 0.16, curve: .easeInOut))
                blur.animateBlur(layer: outgoing.layer, fromRadius: 0.0, toRadius: 6.0, removeOnCompletion: false)
                ConceptsTopicSwipeMotion.ease(0.16, { outgoing.alpha = 0.0 }, completion: { outgoing.removeFromSuperview() })
                incoming.alpha = 0.0
                ComponentTransition(animation: .curve(duration: 0.2, curve: .easeInOut)).animateBlur(layer: incoming.layer, fromRadius: 6.0, toRadius: 0.0, delay: 0.03)
                ConceptsTopicSwipeMotion.ease(0.2, delay: 0.03, { incoming.alpha = 1.0 })
            } else {
                outgoing.removeFromSuperview()
            }
        }
    }

    /// Перед раскрытием чата капсула переезжает и подгоняется под родную, к которой затем переходит.
    func morph(to frame: CGRect, transition: ComponentTransition, positionTransition: ComponentTransition) {
        self.apply(size: frame.size, center: CGPoint(x: frame.midX, y: frame.midY), transition: transition, positionTransition: positionTransition)
    }
}

private final class ConceptsTopicSwipePanel: UIView, UIGestureRecognizerDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    let candidates: [ConceptsTopicSwipeSession.Candidate]
    /// Ряд аватарок: слева значок «Все новые» (если чатов больше одного), правее чаты по свежести.
    let hasList: Bool
    var firstChatRow: Int { return self.hasList ? 1 : 0 }
    private(set) var selectedRow: Int = 0
    var rowCount: Int { return self.candidates.count + self.firstChatRow }
    var isListSelected: Bool { return self.hasList && self.selectedRow == 0 }
    var selectedCandidate: ConceptsTopicSwipeSession.Candidate? {
        let index = self.selectedRow - self.firstChatRow
        return index >= 0 && index < self.candidates.count ? self.candidates[index] : nil
    }

    var selectionChanged: ((Bool) -> Void)?
    var openRequested: ((ConceptsTopicSwipeSession.Candidate) -> Void)?
    var prepareRequested: ((ConceptsTopicSwipeSession.Candidate) -> Void)?
    var dismissRequested: (() -> Void)?

    private let topInset: CGFloat
    private let bottomY: CGFloat
    private let inputPanelHeight: CGFloat
    private let layout: ContainerViewLayout
    // Строка списка — как в родном списке чатов: 76 pt, аватарка 60.
    private let listRowHeight: CGFloat = 76.0
    /// Верх списка под стеклянной шапкой (как у предпросмотров): строки уходят под неё при прокрутке.
    private let listHeaderHeight: CGFloat = 58.0
    // Размеры и прозрачность по расстоянию от выбранной: крупная — мельче — гаснет к краю.
    private let itemSizes: [CGFloat] = [66.0, 48.0, 38.0, 30.0, 24.0]
    private let itemAlphas: [CGFloat] = [1.0, 0.9, 0.6, 0.35, 0.15]
    private let itemGap: CGFloat = 8.0
    private let nameHeight: CGFloat = 22.0
    /// Полоса ряда: стекло аватарки 66 и запас под счётчик над ним.
    private let glassHeight: CGFloat = 76.0
    /// Ход пальца на один чат (и при ведении жеста, и при листании ряда после отпускания).
    static let pitch: CGFloat = 56.0
    /// Сколько пальца на один чат при ведении жеста (лонгпресс).
    static let trackPitch: CGFloat = 38.0
    var itemPitch: CGFloat { return ConceptsTopicSwipePanel.pitch }

    private let dimView = UIView()
    private let blurView = UIVisualEffectView(effect: nil)
    private let cardShadow = UIView()
    private let cardClip = UIView()
    private let previewHost = UIView()
    private let listContainer = UIView()
    private let listHeader = UILabel()
    /// Верх списка гаснет к фону под шапкой (как край прокрутки в родных списках): строки не спорят с капсулой.
    // v33: родной мягкий край (размытие + цвет), как под шапкой списка чатов; был белый градиент — «засвечивал» аватарки.
    private let listTopFade = EdgeEffectView()
    private let listScroll = UIScrollView()
    private var listRows: [ConceptsTopicSwipeRowView] = []
    private let rowContainer = UIView()
    private var items: [ConceptsTopicSwipeAvatarItem] = []
    private let nameView = UIView()
    private let nameLabel = UILabel()
    /// Шапка карточки — стеклянная капсула заголовка поверх предпросмотров (их собственные заголовки скрыты): при смене
    /// чата капсула тянется под новое имя пружиной, текст меняется через прозрачность и размытие.
    private let headerTitle: ConceptsTopicSwipeHeaderPill
    /// Статусы людей для шапки («online», «last seen recently»…) — как в родной шапке чата.
    private var presences: [EnginePeer.Id: EnginePeer.Presence] = [:]
    private var headerPillCenter: CGPoint?
    private var previews: [EnginePeer.Id: ChatController] = [:]
    private var listTopFadeColor: UIColor = .white
    var previewChatNodes: [ChatControllerNode] {
        return self.previews.values.compactMap { ($0 as? ChatControllerImpl)?.chatDisplayNode }
    }
    var currentPreviewChatNode: ChatControllerNode? {
        return (self.currentPreview as? ChatControllerImpl)?.chatDisplayNode
    }
    private weak var currentPreview: ChatController?
    var previewController: ChatController? {
        return self.currentPreview
    }
    private var isPinned = false
    /// До старта появления ряда аватарки скрыты: перекладка панели в эти кадры не должна их показать (было мигание).
    private var itemsHidden = false
    /// v18: стекло родной капсулы «следующий чат», которое перетекает в выбранную аватарку ряда.
    private var morphGlass: GlassBackgroundView?
    /// v49: копия стрелки капсулы лежит в обрезке по форме стекла и стягивается вместе с ним.
    private var morphArrowClip: UIView?
    private var morphingRow: Int?
    private var cardShadowIsAnimatingOpen = false
    private let cardPan = UIPanGestureRecognizer()
    private let rowPan = UIPanGestureRecognizer()
    private var cardPanIsVertical: Bool?
    private var rowPanStartRow = 0
    /// v24: дробная позиция ряда под пальцем (nil — ряд стоит на выбранном чате). Лента едет за пальцем плавно,
    /// а крупной становится та аватарка, что проходит центр (как лента историй в Instagram).
    private var rowPosition: CGFloat?
    private var rowSamples: [(time: Double, position: CGFloat)] = []
    /// Палец держит ряд (удержание): аватарки чуть крупнее.
    private var rowHeld = false
    private var rowPressStartX: CGFloat = 0.0
    private let rowPress = UILongPressGestureRecognizer()
    private let rowFeedback = UISelectionFeedbackGenerator()

    init(context: AccountContext, presentationData: PresentationData, candidates: [ConceptsTopicSwipeSession.Candidate], topInset: CGFloat, bottomY: CGFloat, inputPanelHeight: CGFloat, layout: ContainerViewLayout) {
        self.context = context
        self.presentationData = presentationData
        self.candidates = candidates
        self.hasList = candidates.count > 1
        self.topInset = topInset
        self.bottomY = bottomY
        self.inputPanelHeight = inputPanelHeight
        self.layout = layout
        self.headerTitle = ConceptsTopicSwipeHeaderPill(theme: presentationData.theme)

        super.init(frame: .zero)

        let theme = presentationData.theme
        self.dimView.backgroundColor = UIColor(white: 0.0, alpha: theme.overallDarkAppearance ? 0.4 : 0.12)
        self.dimView.alpha = 0.0
        self.blurView.isUserInteractionEnabled = false
        self.addSubview(self.blurView)
        self.dimView.addGestureRecognizer(self.ownTap(UITapGestureRecognizer(target: self, action: #selector(self.dimTapped))))
        self.addSubview(self.dimView)

        // Карточка предпросмотра (и список поверх неё).
        self.cardShadow.layer.shadowColor = UIColor.black.cgColor
        self.cardShadow.layer.shadowOpacity = 0.22
        self.cardShadow.layer.shadowRadius = 22.0
        self.cardShadow.layer.shadowOffset = CGSize(width: 0.0, height: 8.0)
        self.cardClip.clipsToBounds = true
        self.cardClip.layer.cornerRadius = 28.0
        if #available(iOS 13.0, *) {
            self.cardClip.layer.cornerCurve = .continuous
        }
        self.cardClip.backgroundColor = theme.chatList.backgroundColor
        // Предпросмотр касаний не принимает: иначе его собственная прокрутка забирает свайп, и карточка не идёт за пальцем.
        self.previewHost.isUserInteractionEnabled = false
        self.cardClip.addSubview(self.previewHost)

        self.listContainer.backgroundColor = theme.chatList.itemBackgroundColor
        self.listContainer.alpha = 0.0
        self.listHeader.text = "\(candidates.count) unread chats"
        self.listHeader.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        self.listHeader.textColor = theme.chatList.titleColor
        self.listHeader.textAlignment = .center
        self.listContainer.addSubview(self.listHeader)
        self.listScroll.alwaysBounceVertical = true
        // v50: без системного отступа под строку состояния — у повёрнутой соседней карточки он был другим, и строки
        // живого списка в момент отпускания вставали на ≈19 pt ниже снимка, затем съезжали обратно.
        self.listScroll.contentInsetAdjustmentBehavior = .never
        self.listScroll.isScrollEnabled = false
        self.listScroll.showsVerticalScrollIndicator = false
        // Касание строки — как в родном списке чатов: подсветка при нажатии, чат открывается при отпускании.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(self.listPressed(_:)))
        press.minimumPressDuration = 0.0
        press.allowableMovement = 10.0
        press.cancelsTouchesInView = false
        press.delegate = self
        self.listScroll.addGestureRecognizer(press)
        for candidate in candidates {
            let row = ConceptsTopicSwipeRowView(context: context, theme: theme, candidate: candidate, isCard: false)
            self.listScroll.addSubview(row)
            self.listRows.append(row)
        }
        self.listContainer.addSubview(self.listScroll)
        self.listHeader.isHidden = true
        let listBackground = theme.chatList.itemBackgroundColor
        self.listTopFadeColor = listBackground
        self.listTopFade.isUserInteractionEnabled = false
        self.listContainer.addSubview(self.listTopFade)
        self.cardClip.addSubview(self.listContainer)
        self.headerTitle.isUserInteractionEnabled = false
        self.cardClip.addSubview(self.headerTitle)
        self.cardShadow.addSubview(self.cardClip)
        self.cardShadow.addGestureRecognizer(self.ownTap(UITapGestureRecognizer(target: self, action: #selector(self.cardTapped))))
        // После отпускания: предпросмотр свайпается влево-вправо (следующий/предыдущий чат), вниз — панель закрывается.
        self.cardPan.addTarget(self, action: #selector(self.cardPanned(_:)))
        self.cardPan.delegate = self
        self.cardPan.cancelsTouchesInView = false
        self.cardShadow.addGestureRecognizer(self.cardPan)
        self.addSubview(self.cardShadow)

        // Ряд аватарок снизу и подпись выбранной; после отпускания ряд листается пальцем.
        self.rowContainer.addGestureRecognizer(self.ownTap(UITapGestureRecognizer(target: self, action: #selector(self.rowTapped(_:)))))
        self.rowPan.addTarget(self, action: #selector(self.rowPanned(_:)))
        self.rowPan.delegate = self
        self.rowPan.cancelsTouchesInView = false
        self.rowContainer.addGestureRecognizer(self.rowPan)
        // v22: удержание на ряду — отклик сразу (через 0,15 с: аватарки приподнимаются, лёгкий отклик), дальше ряд едет за пальцем.
        self.rowPress.addTarget(self, action: #selector(self.rowPressed(_:)))
        self.rowPress.minimumPressDuration = 0.15
        self.rowPress.allowableMovement = .greatestFiniteMagnitude
        self.rowPress.delegate = self
        self.rowPress.cancelsTouchesInView = false
        self.rowContainer.addGestureRecognizer(self.rowPress)
        self.addSubview(self.rowContainer)
        if self.hasList {
            let item = ConceptsTopicSwipeAvatarItem(context: context, theme: theme, candidate: nil, listCount: candidates.count)
            self.rowContainer.addSubview(item)
            self.items.append(item)
        }
        for candidate in candidates {
            let item = ConceptsTopicSwipeAvatarItem(context: context, theme: theme, candidate: candidate)
            self.rowContainer.addSubview(item)
            self.items.append(item)
        }
        self.nameView.backgroundColor = UIColor(white: 0.0, alpha: 0.38)
        self.nameView.layer.cornerRadius = self.nameHeight / 2.0
        self.nameLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
        self.nameLabel.textColor = .white
        self.nameLabel.textAlignment = .center
        self.nameView.addSubview(self.nameLabel)
        self.rowContainer.addSubview(self.nameView)
        self.selectedRow = self.firstChatRow
        self.updateItems(animated: false)
        let userIds = candidates.compactMap { candidate -> EnginePeer.Id? in
            if case .user = candidate.peer {
                return candidate.peer.id
            }
            return nil
        }
        let _ = (context.engine.data.get(EngineDataMap(userIds.map(TelegramEngine.EngineData.Item.Peer.Presence.init(id:))))
        |> deliverOnMainQueue).startStandalone(next: { [weak self] map in
            guard let self else {
                return
            }
            for (id, presence) in map {
                if let presence {
                    self.presences[id] = presence
                }
            }
            self.updateHeader(animated: false)
        })
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    // MARK: Раскладка

    private var avatarCenterY: CGFloat {
        return self.bottomY - self.nameHeight - 6.0 - self.glassHeight / 2.0
    }

    /// Верх ряда — верх стеклянной подложки (число непрочитанных над аватаркой в неё помещается).
    private var rowTopY: CGFloat {
        return self.avatarCenterY - self.glassHeight / 2.0
    }

    private var cardRestFrame: CGRect {
        // Карточка занимает всё от строки состояния до ряда: шапка чата под размытием не нужна.
        let top = self.topInset + 6.0
        let bottom = self.rowTopY - 8.0
        // Боковые поля как у родного предпросмотра чата (долгое нажатие в списке): 12 pt.
        return CGRect(x: 12.0, y: top, width: self.bounds.width - 24.0, height: max(120.0, bottom - top))
    }

    private func itemOffset(_ distance: Int) -> CGFloat {
        let count = abs(distance)
        var offset: CGFloat = 0.0
        for index in 0 ..< min(count, 4) {
            offset += (self.itemSizes[index] + self.itemSizes[index + 1]) / 2.0 + self.itemGap
        }
        return distance < 0 ? -offset : offset
    }

    // v45: размер и место аватарки по дробному расстоянию — гладкие (rowSmooth). Было кусочно-линейно: на каждом целом
    // шаге скорость аватарки менялась скачком (20 → 26 px за кадр), а размер выбранной шёл «уголком» — лента шла рывками.
    // В покое (целые расстояния) размеры и места прежние, промежуток между соседями по-прежнему ровно itemGap.
    private lazy var rowSmooth: Bool = ConceptsTopicSwipeTune.v("rowSmooth", 1.0) > 0.5
    private lazy var itemSizeSlopes: [CGFloat] = {
        let sizes = self.itemSizes
        var slopes = [CGFloat](repeating: 0.0, count: sizes.count)
        for index in 1 ..< sizes.count - 1 {
            let a = sizes[index] - sizes[index - 1]
            let b = sizes[index + 1] - sizes[index]
            slopes[index] = a * b > 0.0 ? 2.0 * a * b / (a + b) : 0.0
        }
        return slopes
    }()

    private func smoothSize(_ distance: CGFloat) -> CGFloat {
        let magnitude = abs(distance)
        let last = self.itemSizes.count - 1
        if magnitude >= CGFloat(last) {
            return self.itemSizes[last]
        }
        let whole = Int(floor(magnitude))
        let t = magnitude - CGFloat(whole)
        let t2 = t * t
        let t3 = t2 * t
        return (2.0 * t3 - 3.0 * t2 + 1.0) * self.itemSizes[whole] + (t3 - 2.0 * t2 + t) * self.itemSizeSlopes[whole] + (-2.0 * t3 + 3.0 * t2) * self.itemSizes[whole + 1] + (t3 - t2) * self.itemSizeSlopes[whole + 1]
    }

    private func smoothOffset(_ magnitude: CGFloat) -> CGFloat {
        var offset: CGFloat = 0.0
        var d = magnitude
        while d >= 1.0 {
            offset += (self.smoothSize(d - 1.0) + self.smoothSize(d)) / 2.0 + self.itemGap
            d -= 1.0
        }
        return offset + ((self.smoothSize(d) + self.smoothSize(1.0 - d)) / 2.0 + self.itemGap) * d
    }

    /// Смещение аватарки от центра ряда по расстоянию до выбранной (размеры по уровням разные).
    private func itemOffset(fraction distance: CGFloat) -> CGFloat {
        let magnitude = abs(distance)
        if self.rowSmooth {
            return distance < 0.0 ? -self.smoothOffset(magnitude) : self.smoothOffset(magnitude)
        }
        let whole = min(Int(floor(magnitude)), 4)
        let step = self.itemOffset(min(whole + 1, 4)) - self.itemOffset(min(whole, 3))
        let offset = self.itemOffset(whole) + step * (magnitude - CGFloat(whole))
        return distance < 0.0 ? -offset : offset
    }

    /// Обратное к `itemOffset(fraction:)`: на каком дробном расстоянии от выбранной стоит точка ряда.
    private func itemDistance(offset: CGFloat) -> CGFloat {
        let magnitude = abs(offset)
        if self.rowSmooth {
            var low: CGFloat = 0.0
            var high: CGFloat = 12.0
            for _ in 0 ..< 30 {
                let middle = (low + high) / 2.0
                if self.smoothOffset(middle) < magnitude {
                    low = middle
                } else {
                    high = middle
                }
            }
            return offset < 0.0 ? -low : low
        }
        var whole = 0
        while whole < 3 && self.itemOffset(whole + 1) <= magnitude {
            whole += 1
        }
        let step = self.itemOffset(whole + 1) - self.itemOffset(whole)
        let distance = CGFloat(whole) + (magnitude - self.itemOffset(whole)) / max(1.0, step)
        return offset < 0.0 ? -distance : distance
    }

    private func levelValue(_ values: [CGFloat], _ distance: CGFloat) -> CGFloat {
        let magnitude = min(4.0, abs(distance))
        let whole = min(Int(floor(magnitude)), 3)
        let f = magnitude - CGFloat(whole)
        return values[whole] * (1.0 - f) + values[whole + 1] * f
    }

    private func applyItem(index: Int, width: CGFloat, centerX: CGFloat, look: Bool = true) {
        let item = self.items[index]
        // Место и размер — по дробной позиции ленты (за пальцем). v25: размер раньше менялся рывком по целому шагу,
        // и промежутки между аватарками «скакали».
        let distance = CGFloat(index) - (self.rowPosition ?? CGFloat(self.selectedRow))
        let level = distance
        let x = centerX + self.itemOffset(fraction: distance)
        var alpha = self.levelValue(self.itemAlphas, distance)
        if self.hasList && index == 0 && abs(distance) > 0.5 {
            alpha = max(alpha, 0.75)
        }
        // Ряд не выходит за стекло: у краёв подложки аватарки гаснут.
        if x < 26.0 || x > width - 26.0 || self.itemsHidden {
            alpha = 0.0
        }
        // Пока палец держит ряд, аватарки чуть приподняты (крупнее) — видно, что ряд «взят».
        item.center = CGPoint(x: x, y: self.avatarCenterY - self.rowTopY)
        item.alpha = alpha
        guard look else {
            return
        }
        item.layer.removeAnimation(forKey: "conceptsTopicSwipeSelectBounce")
        let scale = (self.rowSmooth ? self.smoothSize(level) : self.levelValue(self.itemSizes, level)) / ConceptsTopicSwipeAvatarItem.size * (self.rowHeld ? 1.08 : 1.0)
        item.transform = CGAffineTransform(scaleX: scale, y: scale)
        item.setSelected(index == self.selectedRow)
    }

    /// Лента за пальцем: места, размеры и прозрачность — без анимации.
    private func positionItems() {
        let width = self.bounds.width > 0.0 ? self.bounds.width : self.layout.size.width
        UIView.performWithoutAnimation {
            for index in 0 ..< self.items.count where index != self.morphingRow {
                self.applyItem(index: index, width: width, centerX: width / 2.0)
            }
        }
    }

    var isRowScrubbing: Bool {
        return self.rowPosition != nil
    }
    private(set) var rowScrubEndTime: Double = 0.0
    private var pendingSettle: (duration: Double, c1: CGPoint)?

    /// Ряд едет за пальцем: у выбранной размер 48, дальше — мельче и бледнее.
    private func updateItems(animated: Bool, appearing: Bool = false) {
        let width = self.bounds.width > 0.0 ? self.bounds.width : self.layout.size.width
        let centerX = width / 2.0
        if appearing {
            for (index, item) in self.items.enumerated() where index != self.morphingRow {
                item.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
                item.alpha = 0.0
            }
        }
        let apply: () -> Void = {
            for index in 0 ..< self.items.count where index != self.morphingRow {
                self.applyItem(index: index, width: width, centerX: centerX)
            }
        }
        if appearing {
            // Выбранная вырастает первой, остальные следом по очереди — каждая масштабом из точки, родной пружиной.
            let count = self.items.count
            for index in 0 ..< count where index != self.morphingRow {
                let distance = abs(index - self.selectedRow)
                ConceptsTopicSwipeMotion.spring(delay: 0.025 * Double(min(distance, 4)), {
                    self.applyItem(index: index, width: width, centerX: centerX)
                })
            }
        } else if animated && self.rowPosition != nil {
            // Ряд ведёт палец: места и размеры уже стоят по пальцу (`positionItems`).
            UIView.performWithoutAnimation(apply)
        } else if animated, let settle = self.pendingSettle {
            self.pendingSettle = nil
            ConceptsTopicSwipeMotion.bezier(settle.duration, settle.c1, CGPoint(x: CGFloat(ConceptsTopicSwipeTune.v("settleX2", 0.25)), y: 1.0), apply)
        } else if animated {
            // v24: шаг ряда — базовым изингом (резкий разгон, долгое торможение): пружина без перелёта стартовала
            // с нуля скорости, и шаги сливались в ровное, «линейное» движение.
            ConceptsTopicSwipeMotion.ease(0.4, apply)
        } else {
            apply()
        }
        let name = self.isListSelected ? "All unread" : (self.selectedCandidate?.peer.compactDisplayTitle ?? "")
        // Подпись сменяется как заголовки в Telegram: старая гаснет с размытием, новая проявляется из размытия.
        let nameBlur = ConceptsTopicSwipeTune.v("nameBlur", 1.0) > 0.5
        let crossfade = animated && !appearing && self.window != nil && !(self.nameLabel.text ?? "").isEmpty && self.nameLabel.text != name && !self.scrubQuiet
        var outgoing: UILabel?
        if crossfade {
            let old = UILabel()
            old.font = self.nameLabel.font
            old.textColor = self.nameLabel.textColor
            old.textAlignment = .center
            old.text = self.nameLabel.text
            old.bounds = self.nameLabel.bounds
            // Сразу на месте старой подписи: без этого копия выезжала из угла капсулы (подпись «съезжала» при свайпе).
            old.center = self.nameLabel.center
            self.nameView.addSubview(old)
            outgoing = old
        }
        self.nameLabel.text = name
        let nameWidth = min(width - 40.0, ceil(self.nameLabel.sizeThatFits(CGSize(width: 300.0, height: self.nameHeight)).width) + 22.0)
        let nameBounds = CGRect(origin: .zero, size: CGSize(width: nameWidth, height: self.nameHeight))
        self.nameView.center = CGPoint(x: centerX, y: self.bottomY - self.rowTopY - self.nameHeight / 2.0)
        if crossfade {
            ConceptsTopicSwipeMotion.ease(0.25, {
                self.nameView.bounds = nameBounds
                self.nameLabel.frame = nameBounds
                outgoing?.center = CGPoint(x: nameBounds.midX, y: nameBounds.midY)
            })
        } else {
            self.nameView.bounds = nameBounds
            self.nameLabel.frame = nameBounds
        }
        if crossfade, let outgoing {
            outgoing.center = CGPoint(x: self.nameView.bounds.midX, y: self.nameView.bounds.midY)
            let transition = ComponentTransition(animation: .curve(duration: 0.22, curve: .easeInOut))
            if nameBlur {
                transition.animateBlur(layer: outgoing.layer, fromRadius: 0.0, toRadius: 6.0, removeOnCompletion: false)
            }
            ConceptsTopicSwipeMotion.ease(0.22, { outgoing.alpha = 0.0 }, completion: { outgoing.removeFromSuperview() })
            self.nameLabel.alpha = 0.0
            if nameBlur {
                transition.animateBlur(layer: self.nameLabel.layer, fromRadius: 6.0, toRadius: 0.0)
            }
            ConceptsTopicSwipeMotion.ease(0.22, { self.nameLabel.alpha = 1.0 })
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = self.bounds.width
        self.dimView.frame = self.bounds
        self.blurView.frame = self.bounds

        let rowTop = self.rowTopY
        self.rowContainer.frame = CGRect(x: 0.0, y: rowTop, width: width, height: self.bottomY - rowTop + 6.0)
        self.updateItems(animated: false)

        if !self.cardShadowIsAnimatingOpen {
            self.applyCardFrame(self.cardRestFrame, cornerRadius: 28.0)
        }
        if self.currentPreview == nil, let candidate = self.selectedCandidate {
            self.showPreview(for: candidate.peer, animated: false)
        }
        if self.headerPillCenter == nil && !self.cardShadowIsAnimatingOpen {
            self.updateHeader(animated: false)
        }
    }

    private func applyCardFrame(_ frame: CGRect, cornerRadius: CGFloat) {
        // Через bounds и center, а не frame: перекладка не сбрасывает сдвиг карточки за пальцем (transform).
        self.cardShadow.bounds = CGRect(origin: .zero, size: frame.size)
        self.cardShadow.center = CGPoint(x: frame.midX, y: frame.midY)
        self.cardShadow.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerRadius: cornerRadius).cgPath
        self.cardClip.frame = CGRect(origin: .zero, size: frame.size)
        self.cardClip.layer.cornerRadius = cornerRadius
        self.previewHost.frame = CGRect(origin: .zero, size: frame.size)
        self.listContainer.frame = CGRect(origin: .zero, size: frame.size)
        self.listHeader.frame = CGRect(x: 0.0, y: 0.0, width: frame.width, height: self.listHeaderHeight)
        // v28: выросшая рамка прокрутки упиралась в конец списка и сдвигала строки на одну вниз — запас снизу, сдвиг тот же.
        let listOffset = self.listScroll.contentOffset
        self.listScroll.contentInset.bottom = self.cardShadowIsAnimatingOpen ? frame.height : 0.0
        self.listScroll.frame = CGRect(origin: .zero, size: frame.size)
        if self.cardShadowIsAnimatingOpen {
            self.listScroll.contentOffset = listOffset
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fadeFrame = CGRect(x: 0.0, y: 0.0, width: frame.width, height: self.listHeaderHeight + CGFloat(ConceptsTopicSwipeTune.v("fadeExtra", 22.0)))
        self.listTopFade.frame = fadeFrame
        self.listTopFade.update(content: self.listTopFadeColor, blur: true, alpha: CGFloat(ConceptsTopicSwipeTune.v("fadeAlpha", 0.8)), rect: fadeFrame, edge: .top, edgeSize: fadeFrame.height, transition: .immediate)
        CATransaction.commit()
        for (index, row) in self.listRows.enumerated() {
            row.frame = CGRect(x: 0.0, y: self.listHeaderHeight + CGFloat(index) * self.listRowHeight, width: frame.width, height: self.listRowHeight)
        }
        self.listScroll.contentSize = CGSize(width: frame.width, height: self.listHeaderHeight + CGFloat(self.listRows.count) * self.listRowHeight)
        if self.cardShadowIsAnimatingOpen {
            self.listScroll.contentOffset = listOffset
        }
        self.layoutPreview(self.previewLayout(size: frame.size), transition: .immediate)
    }

    /// Раскладка карточки без строки состояния: родная шапка чата рисуется сверху, как в предпросмотре чата из списка.
    private func previewLayout(size: CGSize) -> ContainerViewLayout {
        return ContainerViewLayout(size: size, metrics: LayoutMetrics(widthClass: .compact, heightClass: .compact, orientation: nil), deviceMetrics: self.layout.deviceMetrics, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), reservedCorners: .none, division: nil, additionalInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
    }

    private func layoutPreview(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        guard let preview = self.currentPreview else {
            return
        }
        transition.updateFrame(node: preview.displayNode, frame: CGRect(origin: .zero, size: layout.size))
        preview.containerLayoutUpdated(layout, transition: transition)
    }

    // MARK: Точки для автопилота

    func windowPoint(listRow: Int) -> CGPoint {
        let point = CGPoint(x: self.listScroll.bounds.width / 2.0, y: self.listHeaderHeight + (CGFloat(listRow) + 0.5) * self.listRowHeight)
        return self.listScroll.convert(point, to: nil)
    }

    func rowWindowPoint() -> CGPoint {
        return self.rowContainer.convert(CGPoint(x: self.rowContainer.bounds.width / 2.0, y: self.avatarCenterY - self.rowTopY), to: nil)
    }

    func scrollList(by distance: CGFloat, duration: Double) {
        let maxOffset = max(0.0, self.listScroll.contentSize.height - self.listScroll.bounds.height)
        let target = max(0.0, min(maxOffset, self.listScroll.contentOffset.y + distance))
        // v20: плавное пролистывание ≈1,8 с — мягкий разгон и долгая плавная остановка.
        ConceptsTopicSwipeMotion.bezier(duration, CGPoint(x: 0.4, y: 0.0), CGPoint(x: 0.2, y: 1.0), {
            self.listScroll.contentOffset = CGPoint(x: 0.0, y: target)
        })
    }

    // MARK: Предпросмотр

    private func preview(for peer: EnginePeer) -> ChatController {
        if let preview = self.previews[peer.id] {
            return preview
        }
        let preview = self.context.sharedContext.makeChatController(context: self.context, chatLocation: .peer(id: peer.id), subject: nil, botStart: nil, mode: .standard(.previewing), params: nil)
        preview.canReadHistory.set(false)
        self.previews[peer.id] = preview
        // v18: предпросмотр стоит, как родной чат при входе: новые сообщения сверху под плашкой «Непрочитанные»,
        // не поместились — внизу кнопка вниз со счётчиком. Настоящий чат открывается так же (без докрутки в конец).
        return preview
    }

    private var lastSwapAt: Double = 0.0
    private var pendingSwapPeer: EnginePeer.Id?

    private func showPreview(for peer: EnginePeer, animated: Bool) {
        let preview = self.preview(for: peer)
        self.pendingSwapPeer = nil
        if preview === self.currentPreview {
            return
        }
        // v36: при быстром ведении по ряду смены превью не чаще swapGap — каждая смена стоила кадра, ряд отставал от пальца.
        let swapGap = ConceptsTopicSwipeTune.v("swapGap", 0.0)
        let sinceSwap = CACurrentMediaTime() - self.lastSwapAt
        if animated, swapGap > 0.0, sinceSwap < swapGap {
            self.pendingSwapPeer = peer.id
            Queue.mainQueue().after(swapGap - sinceSwap, { [weak self] in
                if let self, self.pendingSwapPeer == peer.id {
                    self.showPreview(for: peer, animated: true)
                }
            })
            return
        }
        if animated {
            self.lastSwapAt = CACurrentMediaTime()
        }
        let previous = self.currentPreview
        self.currentPreview = preview
        let swapStart = CACurrentMediaTime()
        defer {
            if animated {
                ConceptsTopicSwipeAutopilot.mark("swapMs|\(Int((CACurrentMediaTime() - swapStart) * 1000.0))")
            }
        }
        preview.displayNode.isUserInteractionEnabled = false
        preview.displayNode.view.isHidden = false
        ConceptsTopicSwipePanel.setParked(preview, false)
        self.previewHost.addSubview(preview.displayNode.view)
        self.layoutPreview(self.previewLayout(size: self.cardShadow.bounds.size), transition: .immediate)
        // v44: родная капсула шапки прячется сразу при смене превью. При свайпе по ряду превью меняется позже выбора
        // (swapGap), шапка к этому моменту уже обновлена — родная капсула оставалась видна под копией (двойное стекло).
        if self.headerPillCenter != nil {
            self.nativeTitle(preview)?.alpha = 0.0
        }
        if animated, let previous, ConceptsTopicSwipeTune.v("swapSnap", 1.0) > 0.5 {
            // v34: новый чат сразу непрозрачен, поверх гаснет старый, «запечённый» в растр (один раз на стороне отрисовки).
            // v33 брал снимок старого (snapshotView ≈30–40 мс основного потока) — ряд замирал на 3–4 кадра.
            // Проявление живого чата через alpha (до v33) отрисовывало его целиком на каждом кадре.
            let oldView = previous.displayNode.view
            preview.displayNode.view.alpha = 1.0
            // Растр в 2× (не 3×): гаснущий слой на глаз тот же, отрисовка дешевле — без провалов кадра.
            oldView.layer.rasterizationScale = CGFloat(ConceptsTopicSwipeTune.v("swapRaster", 2.0))
            oldView.layer.shouldRasterize = true
            self.previewHost.bringSubviewToFront(oldView)
            let swapCurve = { (c: Double) -> CGPoint in CGPoint(x: ConceptsTopicSwipeTune.v("swapX\(Int(c))", c == 1 ? 0.3 : 0.25), y: ConceptsTopicSwipeTune.v("swapY\(Int(c))", c == 1 ? 0.0 : 1.0)) }
            let animator = UIViewPropertyAnimator(duration: ConceptsTopicSwipeTune.v("swapDur", 0.15), timingParameters: UICubicTimingParameters(controlPoint1: swapCurve(1), controlPoint2: swapCurve(2)))
            animator.addAnimations({ oldView.alpha = 0.0 })
            animator.addCompletion({ [weak self, weak previous] _ in
                oldView.layer.shouldRasterize = false
                if let self, let previous, previous !== self.currentPreview {
                    self.park(previous)
                } else {
                    oldView.alpha = 1.0
                }
            })
            animator.startAnimation()
        } else if animated, let previous {
            // Перетекание: новый проявляется поверх старого (старый непрозрачен до конца — без провала и вспышки).
            preview.displayNode.view.alpha = 0.0
            // v30: мягче при листании ряда (0,15 → swapDur). v33: ровная S-кривая (swapX1…) вместо базовой —
            // базовая за 2 кадра проявляла половину, смена читалась рывком.
            let swapCurve = { (c: Double) -> CGPoint in CGPoint(x: ConceptsTopicSwipeTune.v("swapX\(Int(c))", c == 1 ? 0.3 : 0.25), y: ConceptsTopicSwipeTune.v("swapY\(Int(c))", c == 1 ? 0.0 : 1.0)) }
            let animator = UIViewPropertyAnimator(duration: ConceptsTopicSwipeTune.v("swapDur", 0.15), timingParameters: UICubicTimingParameters(controlPoint1: swapCurve(1), controlPoint2: swapCurve(2)))
            animator.addAnimations({ preview.displayNode.view.alpha = 1.0 })
            animator.addCompletion({ [weak self, weak previous] _ in
                if let self, let previous, previous !== self.currentPreview {
                    self.park(previous)
                }
            })
            animator.startAnimation()
        } else {
            preview.displayNode.view.alpha = 1.0
            if let previous {
                self.park(previous)
            }
        }
        // v33: соседние собранные предпросмотры снимаются с маски заранее (остаются почти прозрачными позади):
        // снятие маски в момент смены отдавало на отрисовку весь чат — кадр замирал, затем проявление рывком.
        if animated && ConceptsTopicSwipeTune.v("unparkNext", 0.0) > 0.5 {
            let index = self.selectedRow - self.firstChatRow
            for neighbor in [index - 1, index + 1] where neighbor >= 0 && neighbor < self.candidates.count {
                if let next = self.previews[self.candidates[neighbor].peer.id], next !== self.currentPreview {
                    ConceptsTopicSwipePanel.setParked(next, false)
                }
            }
        }
    }

    /// Ушедший предпросмотр остаётся отрисованным (1 %, позади): повторный показ без первой отрисовки — без вспышки.
    /// (v25: спрятанный `isHidden` при показе заново уходил в отрисовку — перелистывание замирало на ≈0,4 с.)
    private func park(_ preview: ChatController) {
        preview.displayNode.view.alpha = 0.01
        ConceptsTopicSwipePanel.setParked(preview, true)
        self.previewHost.sendSubviewToBack(preview.displayNode.view)
    }

    /// v25: отложенный предпросмотр обрезан маской до 2×2 pt — слои остаются отрисованными (показ без задержки),
    /// но до 7 чатов под карточкой больше не смешиваются на весь экран на каждом кадре.
    static func setParked(_ preview: ChatController, _ parked: Bool) {
        let layer = preview.displayNode.view.layer
        if parked {
            if layer.mask == nil {
                let mask = CALayer()
                mask.backgroundColor = UIColor.black.cgColor
                mask.frame = CGRect(x: 0.0, y: 0.0, width: 2.0, height: 2.0)
                layer.mask = mask
            }
        } else {
            layer.mask = nil
        }
    }

    /// Предпросмотры чатов на пути пальца собираются заранее, по одному: при ведении по ряду первый показ
    /// несобранного чата мигал пустым, а его шапка доезжала на место уже на экране.
    func prewarmPath(count: Int) {
        var delay = 0.05
        for candidate in self.candidates.prefix(count) where self.previews[candidate.peer.id] == nil {
            let peer = candidate.peer
            Queue.mainQueue().after(delay, { [weak self] in
                self?.prewarmPreview(for: peer)
            })
            delay += 0.12
        }
    }

    // MARK: Выбор

    func select(row: Int, fromUser: Bool) {
        guard row != self.selectedRow, row >= 0, row < self.rowCount else {
            return
        }
        self.selectedRow = row
        let selectStart = CACurrentMediaTime()
        self.updateSelection(animated: true)
        let selectMid = CACurrentMediaTime()
        self.selectionChanged?(fromUser)
        ConceptsTopicSwipeAutopilot.mark("selMs|\(row)|\(Int((selectMid - selectStart) * 10000.0))|\(Int((CACurrentMediaTime() - selectMid) * 10000.0))")
        // v23: выбранная аватарка отскакивает масштабом (+14 % и обратно с лёгким недолётом).
        // v40: после свайпа по ряду аватарка встаёт без отскока (scrubBounce 0) — лента не «спотыкается» в конце.
        let afterScrub = CACurrentMediaTime() - self.rowScrubEndTime < 0.05 && ConceptsTopicSwipeTune.v("scrubBounce", 1.0) < 0.5
        if self.items.indices.contains(row) && self.rowPosition == nil && !afterScrub {
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
            // v37: у значка «Все новые» отскок мягче (listBounce) — белое стекло вспыхивало резко.
            let amount = self.items[row].candidate == nil ? CGFloat(ConceptsTopicSwipeTune.v("listBounce", 1.0)) : 1.0
            bounce.values = [0.0, 0.14 * amount, -0.04 * amount, 0.0]
            bounce.keyTimes = [0.0, 0.33, 0.66, 1.0]
            bounce.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            bounce.duration = 0.45
            bounce.isAdditive = true
            self.items[row].layer.add(bounce, forKey: "conceptsTopicSwipeSelectBounce")
        }
    }

    private func updateSelection(animated: Bool) {
        self.updateItems(animated: animated)
        self.updateContent(animated: animated)
    }

    /// Содержимое карточки для выбранной позиции: предпросмотр чата или список.
    private func updateContent(animated: Bool) {
        self.finishPendingFlip()
        self.discardPreparedPeek()
        let showList = self.isListSelected
        let wasList = self.listContainer.alpha > 0.5
        if let candidate = self.selectedCandidate {
            self.showPreview(for: candidate.peer, animated: animated && !wasList)
        }
        if animated && showList != wasList {
            // Предпросмотр ↔ список: сначала гаснет старое, новое проявляется следом (затухание через фон карточки),
            // чтобы строки списка не ложились поверх сообщений.
            let outgoing: UIView = showList ? self.previewHost : self.listContainer
            let incoming: UIView = showList ? self.listContainer : self.previewHost
            ConceptsTopicSwipeMotion.ease(0.12, { outgoing.alpha = 0.0 })
            ConceptsTopicSwipeMotion.ease(0.2, delay: 0.08, { incoming.alpha = 1.0 })
        } else {
            self.listContainer.alpha = showList ? 1.0 : 0.0
            self.previewHost.alpha = showList ? 0.0 : 1.0
        }
        self.updateHeader(animated: animated)
    }

    // MARK: Шапка

    private func nativeTitle(_ preview: ChatController?) -> ChatNavigationBarTitleView? {
        return (preview as? ChatControllerImpl)?.chatTitleView
    }

    /// Шапка карточки следует за выбором: место — как у родной капсулы предпросмотра, текст — имя и статус чата
    /// (для списка — «All unread» и число чатов).
    /// Подпись шапки: имя и статус чата; без чата — «All unread» и число чатов.
    private func headerText(for candidate: ConceptsTopicSwipeSession.Candidate?) -> (String, String, Bool) {
        let data = self.presentationData
        guard let peer = candidate?.peer else {
            return ("All unread", "\(self.candidates.count) chats", false)
        }
        let title = peer.displayTitle(strings: data.strings, displayOrder: data.nameDisplayOrder)
        switch peer {
        case let .channel(channel):
            if case .broadcast = channel.info {
                return (title, data.strings.Channel_Status, false)
            }
            return (title, data.strings.Group_Status, false)
        case .legacyGroup:
            return (title, data.strings.Group_Status, false)
        default:
            if let presence = self.presences[peer.id] {
                let (text, isOnline) = stringAndActivityForUserPresence(strings: data.strings, dateTimeFormat: data.dateTimeFormat, presence: presence, relativeTo: Int32(Date().timeIntervalSince1970))
                return (title, text, isOnline)
            }
            return (title, data.strings.LastSeen_Lately, false)
        }
    }

    private func updateHeader(animated: Bool) {
        let (title, subtitle, subtitleIsActive) = self.headerText(for: self.isListSelected ? nil : self.selectedCandidate)
        if self.selectedCandidate != nil, !self.isListSelected {
            if let native = self.nativeTitle(self.currentPreview) {
                if let pill = native.glassPillFrame, native.window != nil {
                    self.headerPillCenter = native.convert(CGPoint(x: pill.midX, y: pill.midY), to: self.cardClip)
                }
                // Родную капсулу прячем, только когда копия знает, где встать (иначе карточка осталась бы без шапки).
                if self.headerPillCenter != nil {
                    native.alpha = 0.0
                }
            }
        }
        guard let center = self.headerPillCenter else {
            self.headerTitle.isHidden = true
            return
        }
        if !self.cardShadowIsAnimatingOpen {
            self.headerTitle.isHidden = false
        }
        self.headerTitle.update(title: title, subtitle: subtitle, subtitleIsActive: subtitleIsActive, center: center, animated: animated && self.window != nil && !self.scrubQuiet)
    }

    /// Родные жесты-свайпы вокруг панели (свайп «назад» навигации), выключенные, пока панель стоит.
    private var disabledNativeGestures: [UIGestureRecognizer] = []

    private func restoreNativeGestures() {
        for recognizer in self.disabledNativeGestures {
            recognizer.isEnabled = true
        }
        self.disabledNativeGestures = []
    }

    func setPinned() {
        self.isPinned = true
        // Пока панель стоит, свайпы принадлежат ей: родной свайп «назад» иначе срабатывал вместе со смахом карточки вправо
        // и закрывал чат.
        var ancestor = self.superview
        while let view = ancestor {
            for recognizer in view.gestureRecognizers ?? [] where recognizer is UIPanGestureRecognizer && recognizer.isEnabled {
                recognizer.isEnabled = false
                self.disabledNativeGestures.append(recognizer)
            }
            ancestor = view.superview
        }
        self.listScroll.isScrollEnabled = true
        Queue.mainQueue().after(ConceptsTopicSwipeTune.v("listSnapDelay", 0.2), { [weak self] in
            self?.prepareListSnapshot()
        })
        Queue.mainQueue().after(ConceptsTopicSwipeTune.v("peekPrepAt", 0.75), { [weak self] in
            self?.prepareNeighborCard()
        })
        // Пока панель стоит, по одному собираем предпросмотры ближайших чатов (скрытыми): иначе создание чата
        // в момент тапа или свайпа держит экран ≈0,2 с. Ближние к выбранному — первыми.
        // Сборка идёт, когда ряд уже встал: сборка чата посреди движения даёт остановку кадра.
        // В списке заранее не собираем — его прокрутка должна идти без остановок; чат по строке собирается при касании.
        if self.isListSelected {
            return
        }
        let selectedIndex = max(0, self.selectedRow - self.firstChatRow)
        let order = self.candidates.indices.sorted(by: { abs($0 - selectedIndex) < abs($1 - selectedIndex) })
        // v12: свайп идёт уже через 0,7 с после отпускания — сборка начинается раньше (0,25 с) и плотнее (0,1 с).
        // v17: старт позже (0,45 с) — сборка шла, пока гасло кольцо и вставал ряд, и давала остановку кадра.
        var delay = 0.45
        // v17: шесть ближайших (было 4): предпросмотр, собранный прямо при свайпе, ещё и докручивается в конец — остановка ≈0,14 с.
        for candidate in order.prefix(ConceptsTopicSwipeClock.pinnedPrewarmCount).map({ self.candidates[$0] }) where self.previews[candidate.peer.id] == nil {
            let peer = candidate.peer
            Queue.mainQueue().after(delay, { [weak self] in
                self?.prewarmPreview(for: peer)
            })
            delay += 0.12
        }
    }

    /// Чаты, чьи предпросмотры собраны заранее и успели разложиться.
    private var preparedPeers = Set<EnginePeer.Id>()

    /// Автопилот: предпросмотр чата, который откроют из списка, собирается заранее — иначе он создавался в момент
    /// раскрытия, и оно застывало на ≈0,2 с.
    /// Предпросмотр строки списка подставляется под непрозрачный список и сразу раскладывается во весь экран, как
    /// при открытии (v24): видео в чате создаёт плеер, когда сообщение впервые попадает на экран, и при раскрытии
    /// это стоило ≈0,18 с неподвижного кадра. Под списком, пока он стоит, этой паузы не видно.
    func prepareListOpen(peer: EnginePeer) {
        self.showPreview(for: peer, animated: false)
        var insets = self.layout.intrinsicInsets
        insets.bottom = max(insets.bottom, self.inputPanelHeight)
        let layout = self.layout.withUpdatedIntrinsicInsets(insets)
        if self.preparedOpenPeer != peer.id {
            self.preparedOpenPeer = peer.id
            self.layoutPreview(layout, transition: .immediate)
        }
    }

    func prepareListOpen(peerId: EnginePeer.Id) {
        if self.isListSelected, let candidate = self.candidates.first(where: { $0.peer.id == peerId }) {
            self.prepareListOpen(peer: candidate.peer)
        }
    }

    private var preparedOpenPeer: EnginePeer.Id?

    func prewarmPreview(peerId: EnginePeer.Id) {
        guard let candidate = self.candidates.first(where: { $0.peer.id == peerId }) else {
            return
        }
        self.prewarmPreview(for: candidate.peer)
    }

    private func prewarmPreview(for peer: EnginePeer) {
        guard self.previews[peer.id] == nil, self.superview != nil else {
            return
        }
        self.preparedPeers.insert(peer.id)
        let preview = self.preview(for: peer)
        preview.displayNode.isUserInteractionEnabled = false
        // Отрисован заранее (1 %, под текущим): первый показ скрытого стоил кадра при свайпе.
        preview.displayNode.view.isHidden = false
        preview.displayNode.view.alpha = 0.01
        self.previewHost.insertSubview(preview.displayNode.view, at: 0)
        let layout = self.previewLayout(size: self.cardShadow.bounds.size)
        preview.displayNode.frame = CGRect(origin: .zero, size: layout.size)
        preview.containerLayoutUpdated(layout, transition: .immediate)
        Queue.mainQueue().after(0.35, { [weak self, weak preview] in
            if let self, let preview, preview !== self.currentPreview, preview.displayNode.view.superview === self.previewHost, preview.displayNode.view.alpha < 0.02 {
                ConceptsTopicSwipePanel.setParked(preview, true)
            }
        })
    }

    // MARK: Касания

    /// Жесты самого чата под панелью не должны перехватывать её тапы.
    private func ownTap(_ recognizer: UITapGestureRecognizer) -> UITapGestureRecognizer {
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        return recognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if (gestureRecognizer === self.cardPan || gestureRecognizer === self.rowPan) && self.isPinned, otherGestureRecognizer is UIPanGestureRecognizer, let view = otherGestureRecognizer.view, !view.isDescendant(of: self) {
            return false
        }
        return true
    }

    /// Родные жесты снаружи панели (свайп «назад» навигации) ждут, пока не откажется свайп карточки или ряда:
    /// иначе смах карточки вправо заодно закрывал чат.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === self.cardPan || gestureRecognizer === self.rowPan, self.isPinned else {
            return false
        }
        guard otherGestureRecognizer is UIPanGestureRecognizer, let view = otherGestureRecognizer.view, !view.isDescendant(of: self) else {
            return false
        }
        return true
    }

    @objc private func rowTapped(_ recognizer: UITapGestureRecognizer) {
        guard self.isPinned else {
            return
        }
        self.cancelRowSettle()
        let location = recognizer.location(in: self.rowContainer)
        for (index, item) in self.items.enumerated() where item.alpha > 0.3 && item.frame.insetBy(dx: -4.0, dy: -8.0).contains(location) {
            // Тап по другой аватарке выбирает её, по выбранной — открывает чат.
            if index != self.selectedRow {
                self.select(row: index, fromUser: true)
            } else if let candidate = item.candidate {
                self.openRequested?(candidate)
            }
            return
        }
    }

    @objc private func rowPanned(_ recognizer: UIPanGestureRecognizer) {
        // Удержание ведёт ряд само.
        guard self.isPinned, self.rowPressIgnored || (self.rowPress.state != .began && self.rowPress.state != .changed) else {
            return
        }
        switch recognizer.state {
        case .began:
            self.rowPanDriving = true
            self.cancelRowSettle()
            self.rowPanStartRow = self.selectedRow
            self.rowPressStartX = recognizer.location(in: self).x - recognizer.translation(in: self).x
            self.scrubRow(translation: recognizer.translation(in: self).x)
        case .changed:
            self.scrubRow(translation: recognizer.translation(in: self).x)
        default:
            self.rowPanDriving = false
            self.endRowScrub()
        }
    }
    private var rowPanDriving = false
    private var rowPressIgnored = false

    @objc private func rowPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard self.isPinned else {
            return
        }
        // v45: свайп без удержания ведёт rowPan; удержание, сработавшее через 0,15 с посреди свайпа, заново ставило точку
        // отсчёта — лента на 2 кадра прыгала вперёд на ≈0,8 шага и обратно, аватарки вырастали на ходу.
        if recognizer.state == .began && self.rowPanDriving {
            self.rowPressIgnored = true
        }
        if self.rowPressIgnored {
            if recognizer.state != .began && recognizer.state != .changed {
                self.rowPressIgnored = false
            }
            return
        }
        switch recognizer.state {
        case .began:
            self.cancelRowSettle()
            // Удержание: ряд «взят» — аватарки чуть приподнимаются, лёгкий отклик.
            self.rowPanStartRow = self.selectedRow
            self.rowPressStartX = recognizer.location(in: self).x
            self.rowFeedback.selectionChanged()
            self.rowHeld = true
            ConceptsTopicSwipeMotion.quickSpring({
                self.updateItems(animated: false)
            })
        case .changed:
            self.scrubRow(translation: recognizer.location(in: self).x - self.rowPressStartX)
        default:
            self.endRowScrub()
        }
    }

    /// Палец влево — дальше по чатам, вправо — назад до значка «Все новые»: 38 pt на чат.
    /// v23: ряд не едет за пальцем непрерывно, а переходит отдельными шагами — на середине шага пружиной к соседней
    /// аватарке, и выбранная отскакивает масштабом.
    // v43: ряд за пальцем и его доводка после отпускания идут по кадрам экрана (как карточка с v31/v42), а не по
    // событиям касания и не анимацией слоёв: события приходят неровно (в кадр 0 или 2) — ряд терял ≈2 кадра за свайп,
    // а анимация доводки начинала показываться на кадр позже последнего положения под пальцем.
    private var rowLink: CADisplayLink?
    private var rowStep: ((CADisplayLink) -> Void)?
    private var scrubSamples: [(time: Double, x: CGFloat)] = []

    @objc private func rowLinkStep(_ link: CADisplayLink) {
        self.rowLinkStart = CACurrentMediaTime()
        self.rowStep?(link)
    }
    private var rowLinkStart: Double = 0.0
    private var rowCommitObserver: CFRunLoopObserver?

    private func startRowLink(_ step: @escaping (CADisplayLink) -> Void) {
        self.rowStep = step
        if self.rowLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(self.rowLinkStep(_:)))
            link.add(to: .main, forMode: .common)
            self.rowLink = link
            // Замер: сколько от начала кадра ряда до конца отправки кадра на отрисовку (метка `cm`, если дольше 4 мс).
            if self.rowCommitObserver == nil, ConceptsTopicSwipeTune.v("rowCommitLog", 1.0) > 0.5 {
                let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2000001, { [weak self] _, _ in
                    guard let self, self.rowLinkStart > 0.0 else {
                        return
                    }
                    let spent = CACurrentMediaTime() - self.rowLinkStart
                    self.rowLinkStart = 0.0
                    if spent > 0.004 {
                        ConceptsTopicSwipeAutopilot.mark("cm|\(Int(spent * 10000.0))")
                    }
                })
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                self.rowCommitObserver = observer
            }
        }
    }

    private func stopRowLink() {
        self.rowLink?.invalidate()
        self.rowLink = nil
        if let observer = self.rowCommitObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.rowCommitObserver = nil
        }
        self.rowStep = nil
        self.scrubSamples.removeAll()
    }

    /// Прерывает доводку ряда (новое действие с рядом или карточкой): ряд сразу встаёт на выбранную аватарку.
    private func cancelRowSettle() {
        guard self.rowSettling else {
            return
        }
        self.rowSettling = false
        self.stopRowLink()
        self.rowPosition = nil
        self.updateItems(animated: false)
    }
    private var rowSettling = false

    private func scrubRow(translation: CGFloat) {
        guard ConceptsTopicSwipeTune.v("scrubLink", 1.0) > 0.5 else {
            self.applyScrub(translation: translation)
            return
        }
        let now = CACurrentMediaTime()
        // Касания идут ровно, 60 в секунду, а доходят пачками (в кадр ни одного, в следующий два): время отсчёта — по ровному
        // шагу от предыдущего, пока он не расходится с настоящим временем больше чем на полтора кадра.
        var time = now
        if let last = self.scrubSamples.last {
            if abs(now - (last.time + 1.0 / 60.0)) < 0.025 {
                time = last.time + 1.0 / 60.0
            } else {
                ConceptsTopicSwipeAutopilot.mark("rowResync|\(Int((now - last.time) * 1000.0))")
            }
        }
        self.scrubSamples.append((time, translation))
        self.scrubSamples.removeAll(where: { now - $0.time > 0.1 })
        if self.rowLink == nil || self.rowSettling {
            self.cancelRowSettle()
            self.scrubTau = nil
            // v45: первый кадр не ставит ряд сразу под палец: жест распознаётся после ≈10 pt пути, ряд прыгал на них и
            // стоял 2 кадра (ждал отсчёты). Теперь этот путь (scrubSlopLeft) выбирается плавно за несколько кадров.
            self.scrubSlopLeft = ConceptsTopicSwipeTune.v("slopDecay", 0.8) > 0.0 ? translation : 0.0
            if self.scrubSlopLeft == 0.0 {
                self.applyScrub(translation: translation)
            }
            self.startRowLink({ [weak self] link in
                guard let self, let last = self.scrubSamples.last else {
                    return
                }
                // v44: кадр показывает палец на момент «время кадра − scrubDelay» (один кадр), положение — между двумя
                // событиями касания. События приходят то до кадра, то после: по последнему событию ряд то стоял кадр,
                // то проходил двойной шаг; с запасом в кадр нужный момент всегда лежит между событиями — шаги ровные.
                let tau = link.timestamp - ConceptsTopicSwipeTune.v("scrubDelay", 1.0 / 60.0)
                self.scrubTau = tau
                var x = last.x
                if let index = self.scrubSamples.lastIndex(where: { $0.time <= tau }) {
                    let a = self.scrubSamples[index]
                    if index + 1 < self.scrubSamples.count {
                        let b = self.scrubSamples[index + 1]
                        x = a.x + (b.x - a.x) * CGFloat((tau - a.time) / max(0.001, b.time - a.time))
                    } else if index > 0 {
                        let before = self.scrubSamples[index - 1]
                        let velocity = (a.x - before.x) / CGFloat(max(0.001, a.time - before.time))
                        x = a.x + velocity * CGFloat(min(1.0 / 30.0, tau - a.time))
                    }
                } else if let first = self.scrubSamples.first {
                    x = first.x
                }
                let workStart = CACurrentMediaTime()
                self.scrubSlopLeft *= CGFloat(ConceptsTopicSwipeTune.v("slopDecay", 0.8))
                self.applyScrub(translation: x - self.scrubSlopLeft)
                ConceptsTopicSwipeAutopilot.mark("rowF|\(Int((self.rowPosition ?? 0.0) * 1000.0))|\(Int((CACurrentMediaTime() - workStart) * 10000.0))|\(Int((last.time - tau) * 1000.0))|\(Int((workStart - link.timestamp) * 1000.0))")
            })
        }
    }
    private var scrubTau: Double?
    /// v45: пока ряд ведёт палец, подпись под рядом и шапка карточки меняются сразу, без перетекания: анимированная смена
    /// на каждом шаге стоила кадра отрисовки (лента стояла кадр и догоняла двойным шагом). На отпускании — как раньше.
    private var scrubQuiet: Bool {
        return self.rowPosition != nil && !self.rowSettling && ConceptsTopicSwipeTune.v("scrubQuiet", 1.0) > 0.5
    }
    private var scrubSlopLeft: CGFloat = 0.0

    private func applyScrub(translation: CGFloat) {
        var raw = CGFloat(self.rowPanStartRow) - translation / ConceptsTopicSwipePanel.trackPitch
        // v37: аватарка под пальцем едет вместе с пальцем (rowLock): шаг ряда у центра 65 pt, а не 38 —
        // раньше лента обгоняла палец в ≈1,5 раза, и кольцо соскальзывало с аватарки.
        if ConceptsTopicSwipeTune.v("rowLock", 0.0) > 0.5 {
            let centerX = (self.bounds.width > 0.0 ? self.bounds.width : self.layout.size.width) / 2.0
            let touched = CGFloat(self.rowPanStartRow) + self.itemDistance(offset: self.rowPressStartX - centerX)
            raw = touched - self.itemDistance(offset: self.rowPressStartX + translation - centerX)
        }
        let last = CGFloat(self.rowCount - 1)
        // За краями ленты — сопротивление, как у прокрутки.
        func rubber(_ x: CGFloat) -> CGFloat { return 0.5 * x / (1.0 + x) }
        let position = raw < 0.0 ? -rubber(-raw) : (raw > last ? last + rubber(raw - last) : raw)
        self.rowPosition = position
        let now = CACurrentMediaTime()
        self.rowSamples.append((now, position))
        self.rowSamples.removeAll(where: { now - $0.time > 0.1 })
        self.positionItems()
        let row = Int(max(0.0, min(last, position)).rounded())
        if row != self.selectedRow {
            // v45 (selDefer): смена выбранной (подпись, шапка, превью) — после отправки кадра ряда, а не внутри него.
            if ConceptsTopicSwipeTune.v("selDefer", 0.0) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let position = self.rowPosition else {
                        return
                    }
                    let row = Int(max(0.0, min(CGFloat(self.rowCount - 1), position)).rounded())
                    if row != self.selectedRow {
                        self.select(row: row, fromUser: true)
                    }
                }
            } else {
                self.select(row: row, fromUser: true)
            }
        }
    }

    /// Отпускание: лента докатывается по инерции (скорость пальца) и встаёт на ближайшую аватарку базовым изингом.
    private func endRowScrub() {
        guard !self.rowSettling, self.rowHeld || self.rowPosition != nil else {
            return
        }
        var target = self.selectedRow
        var releaseVelocity: CGFloat = 0.0
        // v45: скорость на отпускании — по последним 3 кадрам (velWindow): за 0,1 с шаг ряда под пальцем успевает
        // смениться (у центра аватарки крупнее), и доводка стартовала медленнее, чем ряд шёл под пальцем.
        let velWindow = ConceptsTopicSwipeTune.v("velWindow", 0.055)
        if let newest = self.rowSamples.last {
            self.rowSamples.removeAll(where: { newest.time - $0.time > velWindow })
        }
        if let position = self.rowPosition, let first = self.rowSamples.first, let lastSample = self.rowSamples.last, lastSample.time - first.time > 0.01 {
            let velocity = (lastSample.position - first.position) / CGFloat(lastSample.time - first.time)
            releaseVelocity = velocity
            // v38: ведение — свайп с отпусканием на ходу, лента докатывается по инерции дальше (rowFling, было 0,12 с).
            target = Int(max(0.0, min(CGFloat(self.rowCount - 1), position + velocity * CGFloat(ConceptsTopicSwipeTune.v("rowFling", 0.12)))).rounded())
            // v34: доводка продолжает скорость пальца и плавно гаснет (было — базовый изинг с рывком на старте).
            let remaining = CGFloat(target) - position
            let duration = ConceptsTopicSwipeTune.v("settleDur", 0.5)
            if abs(remaining) > 0.01 {
                // v40: потолок наклона settleSlope (было 3) — на быстром свайпе доводка начиналась вдвое медленнее пальца.
                let slope = max(0.0, min(CGFloat(ConceptsTopicSwipeTune.v("settleSlope", 3.0)), velocity * CGFloat(duration) / remaining))
                let x1 = CGFloat(ConceptsTopicSwipeTune.v("settleX1", 0.25))
                self.pendingSettle = (duration, CGPoint(x: x1, y: min(1.0, x1 * slope)))
            }
        }
        self.rowSamples.removeAll()
        // v44: доводка продолжает тот же счёт кадров, что и ведение (тот же CADisplayLink, время кадра − scrubDelay,
        // отсчёт от последнего показанного кадра): отдельный шаг в момент отпускания давал неровные шаги (короткий, двойной).
        let scrubTau = self.rowLink != nil ? self.scrubTau : nil
        self.scrubTau = nil
        if scrubTau == nil {
            self.stopRowLink()
        } else {
            self.rowStep = nil
            self.scrubSamples.removeAll()
        }
        if ConceptsTopicSwipeTune.v("settleLink", 1.0) > 0.5, let start = self.rowPosition, let settle = self.pendingSettle {
            self.pendingSettle = nil
            self.rowHeld = false
            let releasedAt = CACurrentMediaTime()
            self.rowScrubEndTime = releasedAt
            let remaining = CGFloat(target) - start
            let x2 = ConceptsTopicSwipeTune.v("settleX2", 0.25)
            // Без ведения по кадрам (scrubLink 0) — шаг на отпускании, как у карточки (flipLinkLead), время — targetTimestamp.
            let frameDelay = ConceptsTopicSwipeTune.v("scrubDelay", 1.0 / 60.0)
            let startTime = scrubTau ?? (releasedAt - ConceptsTopicSwipeTune.v("settleLinkLead", 0.013))
            self.rowSettling = true
            // Жёсткость не ниже скорость/остаток: иначе пружина перелетела бы цель.
            var springOmega = 0.0
            if ConceptsTopicSwipeTune.v("settleSpring", 1.0) > 0.5 {
                springOmega = ConceptsTopicSwipeTune.v("settleOmega", 14.0)
                if abs(remaining) > 0.001, releaseVelocity / remaining > 0.0 {
                    springOmega = max(springOmega, Double(releaseVelocity / remaining))
                }
            }
            ConceptsTopicSwipeAutopilot.mark("rowEnd|\(Int(start * 1000.0))|\(target)|\(Int(releaseVelocity * 1000.0))|\(Int(springOmega * 10.0))")
            let apply: (Double) -> Void = { [weak self] now in
                guard let self, self.rowSettling else {
                    return
                }
                let workStart = CACurrentMediaTime()
                defer {
                    ConceptsTopicSwipeAutopilot.mark("rowS|\(Int((self.rowPosition ?? CGFloat(target)) * 1000.0))|\(Int((CACurrentMediaTime() - workStart) * 10000.0))")
                }
                // v45: доводка — пружина без перелёта с начальной скоростью пальца (settleOmega): скорость на отпускании
                // не меняется скачком и гаснет ровно. Кривая Безье (settleSpring 0) теряла до трети скорости за первый кадр.
                if springOmega > 0.0 {
                    let t = max(0.0, now - startTime)
                    let left = (Double(remaining) + (springOmega * Double(remaining) - Double(releaseVelocity)) * t) * exp(-springOmega * t)
                    if abs(left) < 0.002 || t > 1.2 {
                        self.rowSettling = false
                        self.stopRowLink()
                        self.rowPosition = nil
                        self.updateItems(animated: false)
                        return
                    }
                    self.rowPosition = CGFloat(target) - CGFloat(left)
                    self.positionItems()
                    return
                }
                let u = min(1.0, max(0.0, (now - startTime) / settle.duration))
                if u >= 1.0 {
                    self.rowSettling = false
                    self.stopRowLink()
                    self.rowPosition = nil
                    self.updateItems(animated: false)
                    return
                }
                let p = ConceptsTopicSwipeMotion.curve(u, Double(settle.c1.x), Double(settle.c1.y), x2, 1.0)
                self.rowPosition = start + remaining * CGFloat(p)
                self.positionItems()
            }
            if target != self.selectedRow {
                self.select(row: target, fromUser: true)
            }
            if scrubTau != nil {
                self.startRowLink({ link in
                    apply(link.timestamp - frameDelay)
                })
            } else {
                apply(releasedAt)
                self.startRowLink({ link in
                    apply(link.targetTimestamp)
                })
            }
            return
        }
        self.stopRowLink()
        self.rowPosition = nil
        self.rowHeld = false
        self.rowScrubEndTime = CACurrentMediaTime()

        if target != self.selectedRow {
            self.select(row: target, fromUser: true)
        } else {
            self.updateItems(animated: true)
        }
    }

    @objc private func cardPanned(_ recognizer: UIPanGestureRecognizer) {
        guard self.isPinned else {
            return
        }
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began, .changed:
            if recognizer.state == .began {
                self.finishPendingFlip()
                self.cardShadow.layer.removeAnimation(forKey: "conceptsTopicSwipeFlip")
            }
            if self.cardPanIsVertical == nil && hypot(translation.x, translation.y) > 8.0 {
                self.cardPanIsVertical = abs(translation.y) > abs(translation.x)
            }
            // Карточка идёт за пальцем с сопротивлением; вниз — только для предпросмотра (список листается сам).
            if self.cardPanIsVertical == false {
                self.trackDrag(translation.x)
            } else if self.cardPanIsVertical == true && !self.isListSelected {
                self.cardShadow.transform = CGAffineTransform(translationX: 0.0, y: max(0.0, translation.y) * 0.5)
            }
        case .ended, .cancelled, .failed:
            self.stopDrag()
            let velocity = recognizer.velocity(in: self)
            let isVertical = self.cardPanIsVertical
            self.cardPanIsVertical = nil
            if recognizer.state == .ended && isVertical == true && !self.isListSelected && (translation.y > 90.0 || velocity.y > 600.0) {
                self.dismissRequested?()
                return
            }
            if recognizer.state == .ended && isVertical == false {
                var direction = 0
                if translation.x < -30.0 || velocity.x < -300.0 {
                    direction = 1
                } else if translation.x > 30.0 || velocity.x > 300.0 {
                    direction = -1
                }
                let row = self.selectedRow + direction
                if direction != 0 && row >= 0 && row < self.rowCount {
                    self.flipCard(to: row, direction: direction, velocity: velocity.x)
                    return
                }
            }
            if let peek = self.peek {
                // Соседняя карточка возвращается за край вместе с текущей и убирается.
                let side: CGFloat = self.cardDragOffset < 0.0 ? 1.0 : -1.0
                let target = self.cardTransform(self.stripNeighbor(of: 0.0, side: side))
                ConceptsTopicSwipeMotion.spring({
                    peek.view.layer.transform = target
                    peek.view.alpha = 0.0
                })
                Queue.mainQueue().after(0.45, { [weak self] in
                    if let self, self.peek?.view === peek.view {
                        self.removePeek()
                    }
                })
            }
            self.cardDragOffset = 0.0
            self.springCard(to: 0.0, stiffness: 440.0, damping: 42.0)
        default:
            break
        }
    }

    // MARK: Соседняя карточка при свайпе

    /// v21: пока палец ведёт карточку, соседняя уже видна вплотную (как в карусели) — раньше она появлялась только
    /// после отпускания, «из ниоткуда». В ней живой предпросмотр соседнего чата (собранный заранее) или снимок списка.
    private var peek: (row: Int, view: UIView, preview: ChatController?)?
    /// Когда карточка последний раз двигалась (пальцем или перелистыванием) — сборку чата откладываем до покоя.
    private(set) var lastCardMotion: Double = 0.0
    var isCardMoving: Bool {
        return self.peek != nil || CACurrentMediaTime() - self.lastCardMotion < 0.25
    }

    private func cardScreenX(_ offset: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = self.cardTransform(offset)
        return (x * t.m11 + t.m41) / max(0.001, x * t.m14 + t.m44)
    }

    /// Сдвиг карточки, у которой край `edge` (в её координатах) на экране стоит в точке `target`.
    private func cardOffset(edge: CGFloat, target: CGFloat) -> CGFloat {
        let width = self.cardShadow.bounds.width
        var lo = -width * 1.6, hi = width * 1.6
        for _ in 0 ..< 40 {
            let mid = (lo + hi) / 2.0
            if self.cardScreenX(mid, edge) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2.0
    }

    /// Сдвиг соседней карточки (справа при side = 1), стоящей вплотную (16 pt) к видимому краю карточки со сдвигом `offset`.
    private func stripNeighbor(of offset: CGFloat, side: CGFloat) -> CGFloat {
        let half = self.cardShadow.bounds.width / 2.0
        // v26: шире (16 → 32 pt, peekGap) — карточки при свайпе стояли слишком близко.
        return self.cardOffset(edge: -side * half, target: self.cardScreenX(offset, side * half) + side * CGFloat(ConceptsTopicSwipeTune.v("peekGap", 32.0)))
    }

    private func updatePeek(offset: CGFloat) {
        let side: CGFloat = offset < 0.0 ? 1.0 : -1.0
        let row = self.selectedRow + Int(side)
        guard abs(offset) > 0.5, row >= 0, row < self.rowCount else {
            self.removePeek()
            return
        }
        if self.peek?.row != row {
            self.removePeek()
            self.makePeek(row: row)
        }
        guard let peek = self.peek else {
            return
        }
        peek.view.layer.removeAllAnimations()
        peek.view.alpha = 1.0
        peek.view.layer.transform = self.cardTransform(self.stripNeighbor(of: offset, side: side))
    }

    private func makePeek(row: Int) {
        if let prepared = self.preparedPeek, prepared.row == row {
            self.preparedPeek = nil
            prepared.view.alpha = 1.0
            if let preview = prepared.preview {
                ConceptsTopicSwipePanel.setParked(preview, false)
            }
            self.peek = prepared
            ConceptsTopicSwipeAutopilot.mark("peek|\(row)|prepared")
            return
        }
        self.discardPreparedPeek()
        guard let superview = self.cardShadow.superview, let (shadow, preview) = self.makeCardView(row: row) else {
            return
        }
        superview.insertSubview(shadow, belowSubview: self.cardShadow)
        self.peek = (row, shadow, preview)
        ConceptsTopicSwipeAutopilot.mark("peek|\(row)")
    }

    /// Отдельная карточка позиции `row` с живым предпросмотром (или снимком списка) и капсулой шапки.
    private func makeCardView(row: Int, shell: (shadow: UIView, clip: UIView)? = nil) -> (UIView, ChatController?)? {
        guard self.cardShadow.superview != nil else {
            return nil
        }
        if row < self.firstChatRow, let card = self.listCard {
            self.listCard = nil
            card.alpha = 1.0
            return (card, nil)
        }
        let (shadow, clip) = shell ?? self.makeCardShell(row: row)
        shadow.alpha = 1.0
        var preview: ChatController?
        let index = row - self.firstChatRow
        if index >= 0 && index < self.candidates.count {
            let peer = self.candidates[index].peer
            if self.previews[peer.id] == nil {
                self.prewarmPreview(for: peer)
            }
            let chat = self.preview(for: peer)
            chat.displayNode.view.isHidden = false
            chat.displayNode.view.alpha = 1.0
            ConceptsTopicSwipePanel.setParked(chat, false)
            chat.displayNode.view.frame = clip.bounds
            clip.insertSubview(chat.displayNode.view, at: 0)
            self.nativeTitle(chat)?.alpha = 0.0
            preview = chat
        } else {
            // Список «Все новые»: снимок (он под предпросмотром прозрачен — на время снимка проявляем).
            // v30: снимок готовится заранее, пока панель стоит (prepareListSnapshot): снятый в начале свайпа он
            // останавливал карточку на ≈5 кадров.
            let image = self.listSnapshot ?? self.renderListSnapshot()
            let imageView = UIImageView(image: image)
            imageView.frame = self.listContainer.frame
            clip.insertSubview(imageView, at: 0)
        }
        return (shadow, preview)
    }

    /// Пустая карточка позиции `row`: тень, скругление и капсула шапки (без содержимого).
    private func makeCardShell(row: Int) -> (shadow: UIView, clip: UIView) {
        let shadow = UIView()
        shadow.isUserInteractionEnabled = false
        shadow.bounds = self.cardShadow.bounds
        shadow.center = self.cardShadow.center
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = self.cardShadow.layer.shadowOpacity
        shadow.layer.shadowRadius = self.cardShadow.layer.shadowRadius
        shadow.layer.shadowOffset = self.cardShadow.layer.shadowOffset
        // v41: тень по готовому контуру — без него тень считалась по содержимому (живой чат) на каждом кадре поворота.
        shadow.layer.shadowPath = self.cardShadow.layer.shadowPath
        let clip = UIView(frame: shadow.bounds)
        clip.clipsToBounds = true
        clip.layer.cornerRadius = self.cardClip.layer.cornerRadius
        clip.layer.cornerCurve = .continuous
        clip.backgroundColor = self.cardClip.backgroundColor
        shadow.addSubview(clip)
        let index = row - self.firstChatRow
        if let center = self.headerPillCenter {
            let pill = ConceptsTopicSwipeHeaderPill(theme: self.presentationData.theme)
            pill.isUserInteractionEnabled = false
            clip.addSubview(pill)
            let (title, subtitle, active) = self.headerText(for: index >= 0 && index < self.candidates.count ? self.candidates[index] : nil)
            pill.update(title: title, subtitle: subtitle, subtitleIsActive: active, center: center, animated: false)
        }
        return (shadow, clip)
    }

    private var listSnapshot: UIImage?
    private var listCard: UIView?

    /// v41: соседняя карточка с чатом (справа) собирается заранее, пока панель стоит, и ждёт почти прозрачной под текущей;
    /// предпросмотр в ней остаётся обрезан маской 2×2 pt до начала свайпа. Собранная в начале свайпа она держала главный
    /// поток ≈40 мс — карточка за пальцем замирала на 1–2 кадра.
    private var preparedPeek: (row: Int, view: UIView, preview: ChatController?)?

    private func prepareNeighborCard() {
        if self.isPinned && !self.isListSelected && self.peek == nil {
            self.prepareSpareShell()
        }
        let row = self.selectedRow + 1
        guard ConceptsTopicSwipeTune.v("peekPrep", 1.0) > 0.5, self.preparedPeek == nil, self.peek == nil, self.isPinned, !self.isListSelected, row >= self.firstChatRow, row < self.rowCount else {
            return
        }
        let index = row - self.firstChatRow
        guard index < self.candidates.count, self.previews[self.candidates[index].peer.id] != nil, let superview = self.cardShadow.superview else {
            return
        }
        let start = CACurrentMediaTime()
        guard let (card, preview) = self.makeCardView(row: row) else {
            return
        }
        if let preview {
            ConceptsTopicSwipePanel.setParked(preview, true)
        }
        card.alpha = 0.01
        card.layer.transform = self.cardTransform(self.stripNeighbor(of: 0.0, side: 1.0))
        superview.insertSubview(card, belowSubview: self.cardShadow)
        self.preparedPeek = (row, card, preview)
        ConceptsTopicSwipeAutopilot.mark("peekPrep|\(row)|\(Int((CACurrentMediaTime() - start) * 1000.0))")
    }

    /// v41: пустая карточка текущего чата (со стеклянной капсулой) — тоже заранее: при перелистывании старая карточка
    /// собиралась в момент отпускания, и первая отрисовка нового стекла роняла кадр.
    private var spareShell: (row: Int, shadow: UIView, clip: UIView)?

    private func prepareSpareShell() {
        let row = self.selectedRow
        guard ConceptsTopicSwipeTune.v("shellPrep", 1.0) > 0.5, self.spareShell?.row != row, row >= self.firstChatRow, row < self.rowCount, let superview = self.cardShadow.superview else {
            return
        }
        self.spareShell?.shadow.removeFromSuperview()
        let (shadow, clip) = self.makeCardShell(row: row)
        shadow.alpha = 0.01
        superview.insertSubview(shadow, belowSubview: self.cardShadow)
        self.spareShell = (row, shadow, clip)
    }

    private func takeSpareShell(row: Int) -> (shadow: UIView, clip: UIView)? {
        guard let spare = self.spareShell else {
            return nil
        }
        self.spareShell = nil
        if spare.row == row {
            return (spare.shadow, spare.clip)
        }
        spare.shadow.removeFromSuperview()
        return nil
    }

    private func discardPreparedPeek() {
        guard let prepared = self.preparedPeek else {
            return
        }
        self.preparedPeek = nil
        self.returnPreview(prepared.preview)
        prepared.view.removeFromSuperview()
    }

    private func renderListSnapshot() -> UIImage {
        let wasAlpha = self.listContainer.alpha
        self.listContainer.alpha = 1.0
        // v49: размытый край шапки (EdgeEffectView) в снимке слоя выходил серым градиентом — в снимке он рисуется
        // обычным градиентом цвета фона списка.
        let fadeWasHidden = self.listTopFade.isHidden
        self.listTopFade.isHidden = true
        let fadeHeight = self.listTopFade.frame.height
        let fadeColor = self.listTopFadeColor
        let image = UIGraphicsImageRenderer(bounds: self.listContainer.bounds).image { context in
            self.listContainer.layer.render(in: context.cgContext)
            if !fadeWasHidden, fadeHeight > 0.0, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [fadeColor.withAlphaComponent(CGFloat(ConceptsTopicSwipeTune.v("fadeAlpha", 0.8))).cgColor, fadeColor.withAlphaComponent(0.0).cgColor] as CFArray, locations: [0.0, 1.0]) {
                context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: fadeHeight), options: [])
            }
        }
        self.listTopFade.isHidden = fadeWasHidden
        self.listContainer.alpha = wasAlpha
        return image
    }

    /// v30: снимок списка для соседней карточки — заранее, пока панель стоит и рядом с выбранным чатом список.
    private func prepareListSnapshot() {
        guard self.listSnapshot == nil, self.isPinned, !self.isListSelected, self.selectedRow - 1 < self.firstChatRow, self.peek == nil else {
            return
        }
        let start = CACurrentMediaTime()
        self.listSnapshot = self.renderListSnapshot()
        // Вся соседняя карточка списка (снимок, стекло капсулы) собирается заранее и стоит почти прозрачной под
        // текущей: собранная в начале свайпа она держала главный поток ≈70 мс.
        if let superview = self.cardShadow.superview, let (card, _) = self.makeCardView(row: self.firstChatRow - 1) {
            card.alpha = 0.01
            superview.insertSubview(card, belowSubview: self.cardShadow)
            self.listCard = card
        }
        ConceptsTopicSwipeAutopilot.mark("listSnapshot|\(Int((CACurrentMediaTime() - start) * 1000.0))")
    }

    /// Предпросмотр из отдельной карточки возвращается к остальным (1 %, позади), если не стал текущим.
    private func returnPreview(_ preview: ChatController?) {
        guard let preview else {
            return
        }
        self.previewHost.insertSubview(preview.displayNode.view, at: 0)
        preview.displayNode.view.frame = self.previewHost.bounds
        if preview !== self.currentPreview {
            self.park(preview)
        }
    }

    /// Убирает соседнюю карточку; её предпросмотр возвращается к остальным (1 %, позади), если не стал текущим.
    private func removePeek() {
        guard let peek = self.peek else {
            return
        }
        self.peek = nil
        self.returnPreview(peek.preview)
        peek.view.removeFromSuperview()
    }

    /// Карточка при свайпе — как на барабане: сдвиг по X и поворот вокруг оси Y с перспективой (край в сторону движения
    /// уходит вглубь). Поворот пропорционален сдвигу — карточка плавно искажается вместе с пальцем.
    private func cardTransform(_ offset: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / 900.0
        let width = max(1.0, self.cardShadow.bounds.width)
        // v15: внешний край ближе к зрителю (карточка справа повёрнута правым краем к нам).
        // v19: поворот сильнее (0,7 → 1,0).
        let angle = -offset / width * 1.0
        // Дальний край не уходит за плоскость экрана (z < 0): там его и соседние слои со стеклом система не рисовала —
        // пропадала половина экрана. Карточка выдвигается к зрителю на глубину поворота с запасом (на самой плоскости
        // край тоже обрезался — у почти выпрямленной карточки пропадала полоса сбоку), масштаб это компенсирует.
        let depth = (width / 2.0 + 24.0) * abs(sin(angle))
        let scale = (900.0 - depth) / 900.0
        transform = CATransform3DTranslate(transform, offset, 0.0, depth)
        transform = CATransform3DScale(transform, scale, scale, 1.0)
        return CATransform3DRotate(transform, angle, 0.0, 1.0, 0.0)
    }

    /// Пружина без перелёта к сдвигу `offset`; в покое (0) карточка возвращается к обычной (плоской) трансформации.
    private func springCard(to offset: CGFloat, stiffness: CGFloat, damping: CGFloat, velocity: CGFloat = 0.0) {
        let animator = UIViewPropertyAnimator(duration: 0.4, timingParameters: UISpringTimingParameters(mass: 1.0, stiffness: stiffness, damping: damping, initialVelocity: CGVector(dx: velocity, dy: velocity)))
        animator.addAnimations({
            self.cardShadow.transform3D = self.cardTransform(offset)
        })
        animator.addCompletion({ [weak self] position in
            if position == .end, offset == 0.0, let self, !self.cardShadowIsAnimatingOpen {
                self.cardShadow.transform = .identity
            }
        })
        animator.startAnimation()
    }

    /// Сдвиг карточки за пальцем (для продолжения движения при смене карточки).
    private var cardDragOffset: CGFloat = 0.0
    // v31: карточка за пальцем двигается по кадрам экрана, а не по событиям касания. События приходят неровно
    // (в кадр бывает 0 или 2), и карточка замирала через кадр-два — свайп выглядел рваным.
    private var dragLink: CADisplayLink?
    private var dragSamples: [(time: Double, x: CGFloat)] = []

    private func trackDrag(_ x: CGFloat) {
        let now = CACurrentMediaTime()
        self.dragSamples.append((now, x))
        self.dragSamples.removeAll(where: { now - $0.time > 0.06 })
        if ConceptsTopicSwipeTune.v("dragPredict", 1.0) < 0.5 {
            self.applyDrag(x)
            return
        }
        if self.dragLink == nil {
            self.applyDrag(x)
            let link = CADisplayLink(target: self, selector: #selector(self.dragStep(_:)))
            link.add(to: .main, forMode: .common)
            self.dragLink = link
        }
    }

    @objc private func dragStep(_ link: CADisplayLink) {
        guard let last = self.dragSamples.last else {
            return
        }
        var x = last.x
        if let first = self.dragSamples.first, last.time - first.time > 0.005 {
            let velocity = (last.x - first.x) / CGFloat(last.time - first.time)
            x += velocity * CGFloat(max(0.0, min(1.0 / 30.0, link.targetTimestamp - last.time)))
        }
        self.applyDrag(x)
    }

    private func applyDrag(_ x: CGFloat) {
        self.lastCardMotion = CACurrentMediaTime()
        self.cardDragOffset = x * 0.85
        self.cardShadow.transform3D = self.cardTransform(self.cardDragOffset)
        self.updatePeek(offset: self.cardDragOffset)
    }

    private func stopDrag() {
        self.dragLink?.invalidate()
        self.dragLink = nil
        self.dragSamples.removeAll()
    }

    /// v42: отложенная смена содержимого после перелистывания «на месте» (см. flipCard); любое новое действие с
    /// карточкой сначала доводит её.
    private var pendingFlip: (() -> Void)?
    private var flipToken = 0

    private var flipLink: CADisplayLink?
    private var flipStep: ((Double) -> Void)?

    @objc private func flipLinkStep(_ link: CADisplayLink) {
        self.flipStep?(link.targetTimestamp)
    }

    private func finishPendingFlip() {
        if let finish = self.pendingFlip {
            self.pendingFlip = nil
            finish()
        }
    }

    /// Свайп карточки как карусель: текущая (снимок) и следующая едут вместе с зазором 16 pt, каждая повёрнута
    /// по оси Y по своему сдвигу; одна пружина без перелёта, стартует со скоростью пальца.
    private func flipCard(to row: Int, direction: Int, velocity: CGFloat = 0.0) {
        self.finishPendingFlip()
        self.cancelRowSettle()
        let width = self.cardShadow.bounds.width
        let side = CGFloat(direction)
        let start = self.cardDragOffset
        let releasedAt = CACurrentMediaTime()
        // v42: соседняя карточка уже на экране (вели пальцем) — перелистывание идёт тем же способом, что и ведение:
        // положение обеих карточек ставится на каждом кадре экрана (flipLink), содержимое не перекладывается, а меняется
        // местами уже в покое (finishPendingFlip). Анимация слоёв, добавленная в момент отпускания, начинала показываться
        // на кадр позже последнего положения под пальцем — карточка замирала на кадр и потом перескакивала.
        if ConceptsTopicSwipeTune.v("flipLink", 1.0) > 0.5, let incoming = self.peek, incoming.row == row {
            self.peek = nil
            let half = width / 2.0
            let oldEnd = self.cardOffset(edge: side * half, target: self.cardScreenX(0.0, -side * half) - side * CGFloat(ConceptsTopicSwipeTune.v("peekGap", 32.0)))
            let distance = max(1.0, abs(oldEnd - start))
            let duration = ConceptsTopicSwipeTune.v("flipDur", 0.55)
            let curveY1 = ConceptsTopicSwipeTune.v("flipY1", 0.4)
            let fingerSpeed = max(1.0, Double(abs(velocity)) * ConceptsTopicSwipeTune.v("flipVk", 1.0))
            let curveX1 = ConceptsTopicSwipeTune.values["flipX1"] ?? max(0.02, min(0.5, curveY1 * Double(distance) / (fingerSpeed * duration)))
            let flipX2 = ConceptsTopicSwipeTune.v("flipX2", 0.0)
            let startTime = releasedAt - ConceptsTopicSwipeTune.v("flipLinkLead", 0.008)
            self.lastCardMotion = releasedAt + duration
            incoming.view.layer.removeAllAnimations()
            incoming.view.alpha = 1.0
            // v44: в карточке списка «Все новые» с отпускания стоит живой список, а не его снимок: снимок (серое пятно
            // вместо размытия у шапки) висел до конца хода, пролистывание под ним уже шло — список потом перескакивал.
            var listHome: (parent: UIView, index: Int)?
            if incoming.preview == nil, row < self.firstChatRow, let parent = self.listContainer.superview, let index = parent.subviews.firstIndex(of: self.listContainer), let clip = incoming.view.subviews.first, let snapshot = clip.subviews.first as? UIImageView {
                listHome = (parent, index)
                UIView.performWithoutAnimation {
                    self.listContainer.alpha = 1.0
                    clip.insertSubview(self.listContainer, aboveSubview: snapshot)
                }
            }
            let apply: (Double) -> Bool = { now in
                let u = min(1.0, max(0.0, (now - startTime) / duration))
                let p = u >= 1.0 ? 1.0 : ConceptsTopicSwipeMotion.curve(u, curveX1, curveY1, flipX2, 1.0)
                let old = start + (oldEnd - start) * CGFloat(p)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.cardShadow.layer.transform = self.cardTransform(old)
                // Старая к концу у самого края экрана: гаснет, чтобы полоска не пропадала рывком.
                self.cardShadow.layer.opacity = Float(max(0.0, min(1.0, (1.0 - p) / 0.25)))
                incoming.view.layer.transform = self.cardTransform(u >= 1.0 ? 0.0 : self.stripNeighbor(of: old, side: side))
                CATransaction.commit()
                return u < 1.0
            }
            self.flipToken += 1
            let token = self.flipToken
            self.pendingFlip = {
                self.flipLink?.invalidate()
                self.flipLink = nil
                self.flipStep = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.cardShadow.transform = .identity
                self.cardShadow.alpha = 1.0
                if let listHome {
                    listHome.parent.insertSubview(self.listContainer, at: listHome.index)
                }
                self.returnPreview(incoming.preview)
                self.updateContent(animated: false)
                incoming.view.removeFromSuperview()
                CATransaction.commit()
                ConceptsTopicSwipeAutopilot.mark("flipDone|\(incoming.row)")
            }
            self.flipStep = { now in
                if apply(now) {
                    return
                }
                self.flipLink?.invalidate()
                self.flipLink = nil
                self.flipStep = nil
                Queue.mainQueue().after(ConceptsTopicSwipeTune.v("flipFinishPad", 0.05), {
                    if self.flipToken == token {
                        self.finishPendingFlip()
                    }
                })
                Queue.mainQueue().after(ConceptsTopicSwipeTune.v("peekPrepAfterFlip", 0.1), {
                    if self.flipToken == token {
                        self.prepareNeighborCard()
                    }
                })
            }
            _ = apply(releasedAt)
            let link = CADisplayLink(target: self, selector: #selector(self.flipLinkStep(_:)))
            link.add(to: .main, forMode: .common)
            self.flipLink = link
            self.cardDragOffset = 0.0
            // Ряд, шапка выбора и вибрация — следующим кадром, как и в обычном перелистывании.
            DispatchQueue.main.async {
                let t0 = CACurrentMediaTime()
                self.selectedRow = row
                self.updateItems(animated: true)
                self.selectionChanged?(true)
                ConceptsTopicSwipeAutopilot.mark("flipMs|\(Int((CACurrentMediaTime() - t0) * 1000.0))|link|\(Int(abs(velocity)))")
            }
            return
        }
        // Ряд, шапка выбора и вибрация — следующим кадром (раньше перекладка панели применяла ряд без анимации).
        DispatchQueue.main.async {
            let t0 = CACurrentMediaTime()
            let oldRow = self.selectedRow
            let oldIsChat = !self.isListSelected
            self.selectedRow = row
            self.updateItems(animated: true)
            self.selectionChanged?(true)
            let t1 = CACurrentMediaTime()
            // v17: старая карточка уходит вплотную перед новой (было: уход за край, пустой экран, приход).
            // v24: старая карточка с чатом — живая (её предпросмотр переносится в отдельную карточку), а не снимок:
            // снимок карточки с чатом и стеклом стоил ≈60–70 мс, и свайп подтормаживал в момент отпускания.
            var snapshot: UIView?
            var oldPreview: ChatController?
            // v42: если соседняя карточка уже на экране (вели пальцем), на отпускании ничего не перекладывается: текущая
            // карточка уезжает как есть, соседняя доезжает на её место, а содержимое меняется местами уже в покое
            // (finishPendingFlip). Раньше в момент отпускания два живых чата переезжали между карточками — главный поток
            // тратил 0–4 мс, но отрисовка пересобирала оба дерева слоёв и теряла кадр (flipInPlace).
            var incoming: (row: Int, view: UIView, preview: ChatController?)?
            if ConceptsTopicSwipeTune.v("flipInPlace", 1.0) > 0.5, let peek = self.peek, peek.row == row {
                incoming = peek
                self.peek = nil
            }
            if incoming == nil {
                if !oldIsChat {
                    snapshot = self.cardShadow.snapshotView(afterScreenUpdates: false)
                }
                self.removePeek()
                self.updateContent(animated: false)
            }
            let t2 = CACurrentMediaTime()
            if incoming == nil, oldIsChat, let (card, preview) = self.makeCardView(row: oldRow, shell: self.takeSpareShell(row: oldRow)) {
                snapshot = card
                oldPreview = preview
            }
            if let snapshot, let superview = self.cardShadow.superview {
                snapshot.isUserInteractionEnabled = false
                snapshot.bounds = self.cardShadow.bounds
                snapshot.center = self.cardShadow.center
                snapshot.layer.transform = self.cardTransform(start)
                superview.insertSubview(snapshot, belowSubview: self.cardShadow)
            }
            ConceptsTopicSwipeAutopilot.mark("flipMs|\(Int((t1 - t0) * 1000.0))|\(Int((t2 - t1) * 1000.0))|\(Int((CACurrentMediaTime() - t2) * 1000.0))")
            // v20: карточки едут одной лентой. Раньше каждая шла своей анимацией к своему сдвигу, а поворот сжимал их
            // по-разному — между ними открывался провал ≈90 pt, и новая появлялась позже старой. Теперь ход ленты
            // считается покадрово: старая идёт от точки отпускания, новая стоит вплотную к её видимому краю (зазор 16 pt).
            let half = width / 2.0
            func newOffset(old: CGFloat) -> CGFloat {
                return self.stripNeighbor(of: old, side: side)
            }
            let oldEnd = self.cardOffset(edge: side * half, target: self.cardScreenX(0.0, -side * half) - side * CGFloat(ConceptsTopicSwipeTune.v("peekGap", 32.0)))
            // Пружина стартует со скоростью пальца. v25: быстрее (ω² 320 → 560). v26: лёгкий отскок в конце —
            // затухание ζ 0,72 вместо 1 (flipW2, flipZeta, flipDur).
            let omega = sqrt(ConceptsTopicSwipeTune.v("flipW2", 560.0))
            let zeta = min(0.999, ConceptsTopicSwipeTune.v("flipZeta", 0.72))
            let omegaD = omega * sqrt(1.0 - zeta * zeta)
            let distance = max(1.0, abs(oldEnd - start))
            let v0 = min(omega * 0.9, abs(velocity) / distance)
            let duration = ConceptsTopicSwipeTune.v("flipDur", 0.55)
            self.lastCardMotion = CACurrentMediaTime() + duration
            let useCurve = ConceptsTopicSwipeTune.v("flipCurve", 1.0) > 0.5
            let curveY1 = ConceptsTopicSwipeTune.v("flipY1", 0.4)
            let fingerSpeed = max(1.0, Double(abs(velocity)) * ConceptsTopicSwipeTune.v("flipVk", 1.0))
            var curveX1 = max(0.02, min(0.5, curveY1 * Double(distance) / (fingerSpeed * duration)))
            // v38: смена превью — базовым изингом пользователя, как по тапу (flipX1 задаёт x1 вместо подбора под палец).
            if let fixedX1 = ConceptsTopicSwipeTune.values["flipX1"] {
                curveX1 = fixedX1
            }
            // v36: x2 0 → flipX2: с x2 = 0 скорость после отпускания вырастала вдвое (карточка «скакала»), с 0,35 — только убывает.
            let flipX2 = ConceptsTopicSwipeTune.v("flipX2", 0.0)
            ConceptsTopicSwipeAutopilot.mark("flipCurve|\(Int(abs(velocity)))|\(Int(distance))|\(curveX1)")
            let count = 60
            var newValues: [NSValue] = []
            var oldValues: [NSValue] = []
            var opacities: [NSNumber] = []
            var keyTimes: [NSNumber] = []
            for i in 0 ... count {
                let t = duration * Double(i) / Double(count)
                // v31: базовый изинг пользователя (0, 0.4, 0, 1) вместо пружины — та читалась как стандартный ease-in-out.
                // Первая точка кривой подобрана под скорость пальца, чтобы карточка не прыгала при отпускании (flipY1).
                let p: Double
                if useCurve {
                    p = i == count ? 1.0 : ConceptsTopicSwipeMotion.curve(t / duration, curveX1, curveY1, flipX2, 1.0)
                } else {
                    p = i == count ? 1.0 : 1.0 - exp(-zeta * omega * t) * (cos(omegaD * t) + (zeta * omega - v0) / omegaD * sin(omegaD * t))
                }
                let old = start + (oldEnd - start) * CGFloat(p)
                oldValues.append(NSValue(caTransform3D: self.cardTransform(old)))
                newValues.append(NSValue(caTransform3D: self.cardTransform(i == count ? 0.0 : newOffset(old: old))))
                // Старая к концу у самого края экрана: гаснет, чтобы полоска не пропадала рывком.
                opacities.append(NSNumber(value: max(0.0, min(1.0, (1.0 - p) / 0.25))))
                keyTimes.append(NSNumber(value: Double(i) / Double(count)))
            }
            self.cardShadow.layer.removeAnimation(forKey: "conceptsTopicSwipeFlip")
            if incoming == nil {
                self.cardShadow.transform = .identity
            }
            let newView: UIView = incoming?.view ?? self.cardShadow
            let oldView: UIView? = incoming != nil ? self.cardShadow : snapshot
            if let incoming {
                incoming.view.layer.removeAllAnimations()
                incoming.view.alpha = 1.0
                incoming.view.layer.transform = self.cardTransform(0.0)
            }
            // v31: ход считается от момента отпускания (+ кадр вперёд): первый показанный кадр уже сдвинут, а не повторяет
            // последнее положение под пальцем — раньше на отпускании карточка стояла 1–2 кадра.
            let lag = min(0.05, CACurrentMediaTime() - releasedAt + ConceptsTopicSwipeTune.v("flipLead", 1.0 / 60.0))
            // v36: отрисовка на отпускании стоит ≈2 кадра, и анимация от прошедшего времени догоняла их одним скачком.
            // Старт на flipDelay позже, до него — первое значение (fillMode backwards): карточка трогается без скачка.
            let flipDelay = ConceptsTopicSwipeTune.v("flipDelay", 0.0)
            let flipBegin = CACurrentMediaTime() - lag + flipDelay
            let newAnimation = CAKeyframeAnimation(keyPath: "transform")
            newAnimation.values = newValues
            newAnimation.keyTimes = keyTimes
            newAnimation.duration = duration
            newAnimation.fillMode = flipDelay > 0.0 ? .backwards : .removed
            newAnimation.beginTime = newView.layer.convertTime(flipBegin, from: nil)
            newView.layer.add(newAnimation, forKey: "conceptsTopicSwipeFlip")
            if ConceptsTopicSwipeTune.v("flipRasterNew", 0.0) > 0.5 {
                self.cardShadow.layer.rasterizationScale = CGFloat(ConceptsTopicSwipeTune.v("swapRaster", 2.0))
                self.cardShadow.layer.shouldRasterize = true
                Queue.mainQueue().after(duration, {
                    self.cardShadow.layer.shouldRasterize = false
                })
            }
            if let snapshot = oldView {
                snapshot.layer.transform = self.cardTransform(oldEnd)
                snapshot.alpha = 0.0
                let oldAnimation = CAKeyframeAnimation(keyPath: "transform")
                oldAnimation.values = oldValues
                oldAnimation.keyTimes = keyTimes
                oldAnimation.duration = duration
                oldAnimation.fillMode = flipDelay > 0.0 ? .backwards : .removed
                oldAnimation.beginTime = snapshot.layer.convertTime(flipBegin, from: nil)
                snapshot.layer.add(oldAnimation, forKey: "conceptsTopicSwipeFlip")
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = opacities
                fade.keyTimes = keyTimes
                fade.duration = duration
                fade.fillMode = flipDelay > 0.0 ? .backwards : .removed
                fade.beginTime = snapshot.layer.convertTime(flipBegin, from: nil)
                snapshot.layer.add(fade, forKey: "conceptsTopicSwipeFlipFade")
                // v35: старая карточка (живой чат со стеклом) на время поворота — растр: её перерисовка под 3D-поворотом
                // роняла кадр через ≈0,1 с после отпускания (flipRasterOld).
                if incoming == nil, ConceptsTopicSwipeTune.v("flipRasterOld", 1.0) > 0.5 {
                    snapshot.layer.rasterizationScale = CGFloat(ConceptsTopicSwipeTune.v("swapRaster", 2.0))
                    snapshot.layer.shouldRasterize = true
                }
                if let incoming {
                    // Конечное положение стоит в самих слоях: смена содержимого может опоздать на кадр без мигания.
                    self.flipToken += 1
                    let token = self.flipToken
                    self.pendingFlip = {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.cardShadow.layer.removeAnimation(forKey: "conceptsTopicSwipeFlip")
                        self.cardShadow.layer.removeAnimation(forKey: "conceptsTopicSwipeFlipFade")
                        self.cardShadow.transform = .identity
                        self.cardShadow.alpha = 1.0
                        self.returnPreview(incoming.preview)
                        self.updateContent(animated: false)
                        incoming.view.removeFromSuperview()
                        CATransaction.commit()
                        ConceptsTopicSwipeAutopilot.mark("flipDone|\(incoming.row)")
                    }
                    Queue.mainQueue().after(duration + ConceptsTopicSwipeTune.v("flipFinishPad", 0.05), {
                        if self.flipToken == token {
                            self.finishPendingFlip()
                        }
                    })
                } else {
                    Queue.mainQueue().after(duration, {
                        // Предпросмотр мог уже вернуться (снова выбран или взят в соседнюю карточку) — тогда не трогаем.
                        if let oldPreview, oldPreview.displayNode.view.isDescendant(of: snapshot) {
                            self.returnPreview(oldPreview)
                        }
                        snapshot.removeFromSuperview()
                    })
                }
            }
            self.cardDragOffset = 0.0
            Queue.mainQueue().after(duration + ConceptsTopicSwipeTune.v("peekPrepAfterFlip", 0.1), {
                self.prepareNeighborCard()
            })
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // В списке вертикальное движение — прокрутка списка, карточку двигает только горизонтальный свайп.
        if gestureRecognizer === self.cardPan, self.isListSelected {
            let velocity = self.cardPan.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y)
        }
        return true
    }

    private var pressedListRow: Int?
    private var pressedListStart: CGPoint = .zero

    @objc private func listPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard self.isPinned, self.isListSelected else {
            return
        }
        let index = Int(floor((recognizer.location(in: self.listScroll).y - self.listHeaderHeight) / self.listRowHeight))
        switch recognizer.state {
        case .began:
            guard index >= 0 && index < self.candidates.count else {
                return
            }
            self.pressedListRow = index
            self.pressedListStart = recognizer.location(in: self)
            self.prepareRequested?(self.candidates[index])
            // Подсветка и предпросмотр строки — через 0,1 с, если палец не повёл (как в родном списке): при прокрутке
            // сборка предпросмотра строки под пальцем впустую останавливала кадр ≈0,13 с.
            Queue.mainQueue().after(0.1, { [weak self] in
                guard let self, self.pressedListRow == index, self.isListSelected else {
                    return
                }
                self.listRows[index].setHighlighted(true)
                // Пока палец на строке, под непрозрачным списком подставляем её предпросмотр — к отпусканию он готов.
                self.prepareListOpen(peer: self.candidates[index].peer)
            })
            // Долгое нажатие (как в родном списке) — предпросмотр этого чата в карточке вместо открытия.
            Queue.mainQueue().after(0.45, { [weak self] in
                guard let self, self.pressedListRow == index, self.isListSelected else {
                    return
                }
                self.pressedListRow = nil
                self.listRows[index].setHighlighted(false)
                self.select(row: index + self.firstChatRow, fromUser: true)
            })
        case .changed:
            // Палец повёл — это прокрутка списка, а не нажатие: подсветка снимается, чат не открывается.
            let location = recognizer.location(in: self)
            if let pressed = self.pressedListRow, hypot(location.x - self.pressedListStart.x, location.y - self.pressedListStart.y) > 10.0 {
                self.pressedListRow = nil
                self.listRows[pressed].setHighlighted(false)
            }
        case .ended:
            guard let pressed = self.pressedListRow else {
                return
            }
            self.pressedListRow = nil
            if pressed == index {
                self.isUserInteractionEnabled = false
                self.openRequested?(self.candidates[pressed])
            } else {
                self.listRows[pressed].setHighlighted(false)
            }
        case .cancelled, .failed:
            if let pressed = self.pressedListRow {
                self.pressedListRow = nil
                self.listRows[pressed].setHighlighted(false)
            }
        default:
            break
        }
    }

    @objc private func cardTapped() {
        self.finishPendingFlip()
        self.cancelRowSettle()
        if self.isPinned, let candidate = self.selectedCandidate {
            self.openRequested?(candidate)
        }
    }

    @objc private func dimTapped() {
        self.dismissRequested?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Пока палец ведёт жест, панель касаний не принимает.
        if !self.isPinned {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    // MARK: Появление, исчезновение, раскрытие

    /// Размытие на весь экран создаётся заранее (аниматор на нуле): первый запуск размытия при появлении
    /// стоил пропуска кадров.
    private var blurAnimator: UIViewPropertyAnimator?

    func prepareBlur() {
        let blurStyle: UIBlurEffect.Style = self.presentationData.theme.overallDarkAppearance ? .systemThinMaterialDark : .systemUltraThinMaterialLight
        // Размытие и затемнение — 0,45 с с медленным стартом: даже малый радиус размытия сразу меняет весь экран,
        // поэтому радиус сначала растёт медленно — на глаз размытие нарастает ровно, без скачка в первых кадрах.
        // v26: фон менялся ещё ≈0,4 с после того, как превью встало — короче и без медленного старта (blurDur, blurX1).
        let animator = UIViewPropertyAnimator(duration: ConceptsTopicSwipeTune.v("blurDur", 0.3), timingParameters: UICubicTimingParameters(controlPoint1: CGPoint(x: ConceptsTopicSwipeTune.v("blurX1", 0.2), y: 0.0), controlPoint2: CGPoint(x: 0.0, y: 1.0)))
        animator.isUserInteractionEnabled = true
        animator.addAnimations({
            self.dimView.alpha = 1.0
            self.blurView.effect = UIBlurEffect(style: blurStyle)
        })
        animator.fractionComplete = 0.0
        self.blurAnimator = animator
    }

    /// v28: панель, собранная, пока чат ещё не в окне (сразу после открытия), теряла паузу размытия — при втором
    /// появлении фон размывался скачком, а затемнение догоняло. В окне — собираем размытие заново.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil, self.alpha < 0.02, let animator = self.blurAnimator, animator.state == .active, !animator.isRunning {
            animator.stopAnimation(true)
            self.blurView.effect = nil
            self.dimView.alpha = 0.0
            self.prepareBlur()
            ConceptsTopicSwipeAutopilot.mark("blurReprepared")
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        self.restoreNativeGestures()
        // Панель, собранная заранее и так и не показанная: аниматор на паузе нельзя бросать — останавливаем.
        if newSuperview == nil, let animator = self.blurAnimator, animator.state == .active, !animator.isRunning {
            animator.stopAnimation(true)
            self.blurAnimator = nil
        }
    }

    /// v18: родная капсула «следующий чат» (стрелка и аватарка на стекле) не гаснет, а перетекает в выбранную аватарку ряда:
    /// её стекло стягивается в круг аватарки, аватарка растёт на месте, стрелка гаснет; остальные аватарки вырастают рядом.
    private func beginControlMorph(_ control: UIView) {
        guard control.window != nil, self.selectedCandidate != nil, self.items.indices.contains(self.selectedRow) else {
            return
        }
        // Стекло капсулы — слой шириной 56 со скруглением в половину ширины (ChatOverscrollControl).
        func capsuleLayer(_ layer: CALayer) -> CALayer? {
            if abs(layer.bounds.width - 56.0) < 0.5, layer.bounds.height > 58.0, layer.cornerRadius > 20.0 {
                return layer
            }
            for sublayer in layer.sublayers ?? [] {
                if let found = capsuleLayer(sublayer) {
                    return found
                }
            }
            return nil
        }
        guard let capsule = capsuleLayer(control.layer) else {
            return
        }
        let rect = capsule.convert(capsule.bounds, to: self.rowContainer.layer)
        guard rect.width > 20.0, rect.height > 20.0 else {
            return
        }
        let item = self.items[self.selectedRow]
        let glass = GlassBackgroundView()
        glass.isUserInteractionEnabled = false
        glass.frame = rect
        glass.update(size: rect.size, cornerRadius: rect.width / 2.0, isDark: self.presentationData.theme.overallDarkAppearance, tintColor: .init(kind: .panel), transition: .immediate)
        self.rowContainer.insertSubview(glass, belowSubview: item)
        self.morphGlass = glass
        // Родная капсула заменяется своей копией поверх (в тот же кадр), копия гаснет, пока стекло под ней проявляется.
        if let snapshot = control.snapshotView(afterScreenUpdates: false) {
            snapshot.isUserInteractionEnabled = false
            snapshot.frame = control.convert(control.bounds, to: self.rowContainer)
            self.rowContainer.addSubview(snapshot)
            // v47: стрелка уходит отдельно — прозрачность и размытие с первого кадра (было: гасла вместе с копией капсулы
            // после задержки, одной прозрачностью). В копии капсулы на её месте вырез, поверх — копия стрелки.
            func arrowLayer(_ layer: CALayer) -> CALayer? {
                if layer.contents != nil, !layer.isHidden, layer.opacity > 0.5, layer.bounds.width > 8.0, layer.bounds.width < 40.0, layer.bounds.height > 8.0, layer.bounds.height < 40.0 {
                    let center = layer.convert(CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), to: capsule)
                    if abs(center.x - capsule.bounds.midX) < 8.0, center.y > 4.0, center.y < 52.0 {
                        return layer
                    }
                }
                for sublayer in layer.sublayers ?? [] {
                    if let found = arrowLayer(sublayer) {
                        return found
                    }
                }
                return nil
            }
            let arrowDuration = ConceptsTopicSwipeTune.v("morphArrowDur", 0.2)
            if arrowDuration > 0.0, let arrow = arrowLayer(capsule) {
                let arrowRect = arrow.convert(arrow.bounds, to: self.rowContainer.layer)
                let hole = CAShapeLayer()
                let path = UIBezierPath(rect: snapshot.bounds)
                path.append(UIBezierPath(rect: self.rowContainer.convert(arrowRect, to: snapshot).insetBy(dx: -2.0, dy: -2.0)))
                hole.path = path.cgPath
                hole.fillRule = .evenOdd
                snapshot.layer.mask = hole
                let copy = CALayer()
                copy.contents = arrow.contents
                copy.contentsScale = arrow.contentsScale
                copy.contentsGravity = arrow.contentsGravity
                // v49: стрелка обрезана по капсуле и едет с её верхом — при стягивании стекла она торчала над ним.
                let clip = UIView(frame: rect)
                clip.isUserInteractionEnabled = false
                clip.clipsToBounds = true
                clip.layer.cornerRadius = rect.width / 2.0
                // Под аватаркой: растущая аватарка закрывает стрелку, а не стрелка ложится на лицо.
                self.rowContainer.insertSubview(clip, belowSubview: item)
                self.morphArrowClip?.removeFromSuperview()
                self.morphArrowClip = clip
                copy.frame = arrowRect.offsetBy(dx: -rect.minX, dy: -rect.minY)
                copy.opacity = 0.0
                clip.layer.addSublayer(copy)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1.0 as NSNumber
                fade.toValue = 0.0 as NSNumber
                fade.duration = arrowDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                copy.add(fade, forKey: "conceptsTopicSwipeArrowFade")
                ComponentTransition(animation: .curve(duration: arrowDuration, curve: .easeInOut)).animateBlur(layer: copy, fromRadius: 0.0, toRadius: CGFloat(ConceptsTopicSwipeTune.v("morphArrowBlur", 6.0)), removeOnCompletion: false)
                Queue.mainQueue().after(max(arrowDuration + 0.05, 0.5), { [weak self, weak clip] in
                    clip?.removeFromSuperview()
                    if let self, self.morphArrowClip === clip {
                        self.morphArrowClip = nil
                    }
                })
                ConceptsTopicSwipeAutopilot.mark("arrowFade|\(Int(arrowRect.width))|\(Int(arrowRect.height))")
            }
            ConceptsTopicSwipeMotion.ease(0.15, delay: ConceptsTopicSwipeTune.v("morphSnapDelay", 0.05), { snapshot.alpha = 0.0 }, completion: { snapshot.removeFromSuperview() })
        }
        control.alpha = 0.0
        // Аватарка стартует на месте и в размере аватарки капсулы (внизу капсулы, 44 из 56).
        let inner = ConceptsTopicSwipeAvatarItem.size - ConceptsTopicSwipeAvatarItem.inset * 2.0
        let scale = rect.width * (44.0 / 56.0) / inner
        item.setMorphing(true, animated: false)
        item.center = CGPoint(x: rect.midX, y: rect.maxY - rect.width / 2.0)
        item.transform = CGAffineTransform(scaleX: scale, y: scale)
        item.alpha = 1.0
        self.morphingRow = self.selectedRow
        // Старт через 3 кадра: в кадре порога система занята запуском панели (размытие, ряд),
        // и пружина, стартовавшая в нём, проскакивала первые кадры — капсула «схлопывалась» рывком.
        let width = self.bounds.width > 0.0 ? self.bounds.width : self.layout.size.width
        let row = self.selectedRow
        // v47: задержка в настройках (morphDelay): 0,05 с вместе с долгим кадром порога читались как пауза ≈6 кадров.
        Queue.mainQueue().after(ConceptsTopicSwipeTune.v("morphDelay", 0.05), { [weak self] in
            self?.runControlMorph(row: row, width: width, centerX: width / 2.0)
        })
    }

    private func runControlMorph(row: Int, width: CGFloat, centerX: CGFloat) {
        guard let glass = self.morphGlass, self.items.indices.contains(row) else {
            self.morphingRow = nil
            return
        }
        let item = self.items[row]
        let fromCenter = item.center
        let fromTransform = item.transform
        let wasHidden = self.itemsHidden
        self.itemsHidden = false
        self.applyItem(index: row, width: width, centerX: centerX)
        self.itemsHidden = wasHidden
        item.alpha = 1.0
        let toCenter = item.center
        let toTransform = item.transform
        item.center = fromCenter
        item.transform = fromTransform
        let size = ConceptsTopicSwipeAvatarItem.size * toTransform.a
        let target = CGRect(x: toCenter.x - size / 2.0, y: toCenter.y - size / 2.0, width: size, height: size)
        // v21: одно движение — базовый изинг 0,45 с; счётчик проявляется по ходу, а не после.
        let transition = ComponentTransition(animation: .curve(duration: 0.45, curve: .custom(0.0, 0.4, 0.0, 1.0)))
        transition.setPosition(view: item, position: toCenter)
        transition.setTransform(view: item, transform: CATransform3DMakeAffineTransform(toTransform))
        transition.setFrame(view: glass, frame: target)
        if let arrowClip = self.morphArrowClip {
            transition.setFrame(view: arrowClip, frame: target)
            transition.setCornerRadius(layer: arrowClip.layer, cornerRadius: size / 2.0)
        }
        glass.update(size: target.size, cornerRadius: size / 2.0, isDark: self.presentationData.theme.overallDarkAppearance, tintColor: .init(kind: .panel), transition: transition)
        item.showBadge(duration: 0.25, delay: 0.15)
        // v22: инерция — аватарка со стеклом по ходу того же движения проседает вниз и плавно
        // возвращается к 0,45 с: затухающий синус поверх перелёта, а не отдельный отскок после остановки (v23: ≈15 pt к 0,11 с, на глаз ≈12).
        let dipDuration = 0.7
        var dipValues: [CGFloat] = []
        for step in 0 ... 42 {
            let t = dipDuration * Double(step) / 42.0
            dipValues.append(step == 42 ? 0.0 : CGFloat(48.0 * exp(-7.0 * t) * sin(7.0 * t)))
        }
        for layer in [item.layer, glass.layer] + (self.morphArrowClip.flatMap { [$0.layer] } ?? []) {
            let dip = CAKeyframeAnimation(keyPath: "position.y")
            dip.values = dipValues
            dip.calculationMode = .linear
            dip.duration = dipDuration
            dip.isAdditive = true
            layer.add(dip, forKey: "conceptsTopicSwipeDip")
        }
        Queue.mainQueue().after(0.45, { [weak self, weak glass] in
            // Стекло капсулы совпало со стеклом аватарки — подмена незаметна.
            item.setMorphing(false, animated: false)
            glass?.removeFromSuperview()
            if let self, self.morphGlass === glass {
                self.morphGlass = nil
                self.morphingRow = nil
            }
        })
    }

    func animateIn(control: UIView? = nil) {
        let a0 = CACurrentMediaTime()
        self.layoutIfNeeded()
        let a1 = CACurrentMediaTime()
        self.updateHeader(animated: false)
        let a2 = CACurrentMediaTime()
        // Первый кадр — только начальные состояния и старт размытия; карточка стартует следующим кадром, ряд — через один:
        // запуск всего сразу на пороге давал пропуск 2–3 кадров.
        if let animator = self.blurAnimator {
            animator.startAnimation()
        } else {
            let blurStyle: UIBlurEffect.Style = self.presentationData.theme.overallDarkAppearance ? .systemThinMaterialDark : .systemUltraThinMaterialLight
            ConceptsTopicSwipeMotion.bezier(0.45, CGPoint(x: 0.55, y: 0.0), CGPoint(x: 0.35, y: 1.0), {
                self.dimView.alpha = 1.0
                self.blurView.effect = UIBlurEffect(style: blurStyle)
            })
        }
        let rest = self.cardShadow.bounds
        let scale: CGFloat = 0.92
        self.cardShadow.transform = CGAffineTransform(translationX: 0.0, y: rest.height * (1.0 - scale) * 0.5 + 12.0).scaledBy(x: scale, y: scale)
        self.cardShadow.alpha = 0.0
        self.nameView.alpha = 0.0
        self.itemsHidden = true
        for item in self.items {
            item.alpha = 0.0
        }
        self.rowContainer.transform = .identity
        self.rowContainer.alpha = 1.0
        let a3 = CACurrentMediaTime()
        if let control {
            self.beginControlMorph(control)
        }
        // v43: замер появления по частям, мс: раскладка, шапка, размытие и стартовые состояния, перетекание капсулы.
        let ams = { (a: Double, b: Double) in Int((b - a) * 1000.0) }
        ConceptsTopicSwipeAutopilot.mark("inMs|\(ams(a0, a1))|\(ams(a1, a2))|\(ams(a2, a3))|\(ams(a3, CACurrentMediaTime()))")

        // Предпросмотр поднимается от ряда: масштаб 0,92 → 1 родной пружиной, проявление 0,3 с с мягким стартом.
        Queue.mainQueue().after(0.016, {
            ConceptsTopicSwipeMotion.spring({
                self.cardShadow.transform = .identity
            })
            // v27: 0,3 → 0,18 с (cardFade): полупрозрачная карточка над ещё размывающимся фоном читалась как смена фона.
            ConceptsTopicSwipeMotion.standard(ConceptsTopicSwipeTune.v("cardFade", 0.18), delay: 0.015, {
                self.cardShadow.alpha = 1.0
            })
        })
        Queue.mainQueue().after(0.033, {
            // Подпись проявляется, когда панель ввода под ней уже размыта: не ложится поверх кнопки чата.
            ConceptsTopicSwipeMotion.standard(0.25, delay: 0.17, {
                self.nameView.alpha = 1.0
            })
            // Аватарки появляются масштабом, одна за другой.
            self.itemsHidden = false
            self.updateItems(animated: true, appearing: true)
        })
    }

    func animateOut(completion: @escaping () -> Void) {
        self.finishPendingFlip()
        self.cancelRowSettle()
        self.isUserInteractionEnabled = false
        self.restoreNativeGestures()
        ConceptsTopicSwipeMotion.ease(0.3, {
            self.blurView.effect = nil
            self.alpha = 0.0
            self.cardShadow.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }, completion: {
            self.removeFromSuperview()
            completion()
        })
    }

    /// Карточка во весь экран закрывает всё: размытие и ряд под ней убираются, чтобы панель гасла одним слоем.
    func prepareForFadeOut() {
        self.blurView.isHidden = true
        self.dimView.isHidden = true
        self.rowContainer.isHidden = true
    }

    /// v20: к последней трети раскрытия (карточка почти во весь экран, размытия вокруг уже не видно) панель встаёт внутрь
    /// настоящего чата — под его шапку и нижнюю панель, и они проявляются ещё до конца раскрытия (было: ≈0,3 с после него).
    /// Сами кнопки переносить нельзя: узлы чата тут же забирают свои виды обратно. Подпись шапки скрыта: её место занимает
    /// капсула карточки, перетекающая в родную.
    func embed(in chat: ChatControllerImpl) {
        guard let navigationBar = chat.navigationBar?.view, let container = navigationBar.superview else {
            return
        }
        // v22: капсула карточки к этому моменту ещё доезжает до места родной — подпись настоящей шапки встаёт туда,
        // где капсула сейчас, и доезжает тем же ходом (было: подпись появлялась на 3 pt выше — шапка «дёргалась»).
        var pillOffset: CGPoint?
        if !self.openedFromList, let title = chat.chatTitleView, let pill = title.glassPillFrame, let presentation = self.headerTitle.layer.presentation() {
            let current = presentation.convert(presentation.bounds, to: nil)
            let target = title.convert(pill, to: nil)
            pillOffset = CGPoint(x: current.midX - target.midX, y: current.midY - target.midY)
        }
        let frame = self.convert(self.bounds, to: container)
        container.insertSubview(self, belowSubview: navigationBar)
        self.frame = frame
        if let pillOffset, let title = chat.chatTitleView, abs(pillOffset.x) + abs(pillOffset.y) > 0.5 {
            let animation = CASpringAnimation(keyPath: "position")
            animation.mass = 1.0
            animation.stiffness = 440.0
            animation.damping = 42.0
            animation.fromValue = NSValue(cgPoint: pillOffset)
            animation.toValue = NSValue(cgPoint: .zero)
            animation.isAdditive = true
            animation.duration = animation.settlingDuration
            title.layer.add(animation, forKey: "conceptsTopicSwipeEmbed")
            ConceptsTopicSwipeAutopilot.mark("pillOffset|\(Int(pillOffset.x))|\(Int(pillOffset.y))")
        }
        // Капсула карточки под настоящей подписью больше не нужна: двойной край не виден.
        // v47: её отложенное угасание из animateZoomOpen (старт через 0,2 с) держало капсулу видимой ещё ≈5 кадров —
        // два стекла друг на друге, капсула шапки на это время светлела. Снимаем его, прячем сразу.
        for key in self.headerTitle.layer.animationKeys() ?? [] where key.lowercased().contains("opacity") {
            self.headerTitle.layer.removeAnimation(forKey: key)
        }
        self.headerTitle.alpha = 0.0
        // v21: подпись шапки настоящего чата видна сразу, поверх такой же подписи карточки: стекло карточки при переезде
        // на 2–3 кадра терялось, и подпись «мигала» прозрачностью. Проявляются только «назад», аватарка и нижняя панель.
        var controls: [UIView] = [chat.chatDisplayNode.inputPanelContainerNode.view, chat.chatDisplayNode.navigateButtons.view]
        // v23: фон шапки (размытие и затемнение у края, во всю ширину) виден сразу, а шапка карточки под ним скрыта:
        // раньше фон проявлялся поверх такого же фона карточки — шапка становилась то светлее, то темнее.
        // Проявляются только кнопки («назад», аватарка) и, если открыли из списка, подпись.
        // Фон шапки (размытие у края, во всю ширину) проявляется отдельно — плавно, с медленным стартом за 0,3 с:
        // резкое появление давало вспышку светлее на 1–2 кадра.
        let barWidth = navigationBar.bounds.width
        var backgrounds: [UIView] = []
        // Подпись настоящей шапки видна сразу, если в карточке была своя (из ряда — капсула, из списка — шапка
        // собранного заранее предпросмотра); иначе проявляется вместе с кнопками.
        // v50: из списка подпись проявляется вместе с кнопками (раньше капсула появлялась на ≈0,15 с раньше «назад» и аватарки).
        let keepTitle = !self.openedFromList
        func collect(_ view: UIView) {
            for subview in view.subviews where !subview.isHidden {
                if keepTitle, let title = chat.chatTitleView, title === subview || title.isDescendant(of: subview) {
                    if title !== subview {
                        collect(subview)
                    }
                } else if subview.bounds.width < barWidth * 0.8 {
                    controls.append(subview)
                } else if subview.subviews.isEmpty {
                    backgrounds.append(subview)
                } else {
                    collect(subview)
                }
            }
        }
        collect(navigationBar)
        // v47: шапка предпросмотра (затемнение у края под капсулой) уходит тем же ходом, каким проявляется фон настоящей
        // шапки. Раньше пряталась сразу, а новый фон проявлялся 0,3 с — капсула на это время светлела.
        if !self.openedFromList, let previewBar = self.currentPreview?.navigationBar?.view, !previewBar.isHidden {
            if let native = self.nativeTitle(self.currentPreview) {
                for key in native.layer.animationKeys() ?? [] where key.lowercased().contains("opacity") {
                    native.layer.removeAnimation(forKey: key)
                }
                native.alpha = 0.0
            }
            UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseInOut], animations: {
                previewBar.alpha = 0.0
            }, completion: { _ in
                previewBar.isHidden = true
                previewBar.alpha = 1.0
            })
        } else {
            self.currentPreview?.navigationBar?.view.isHidden = true
        }
        for view in controls + backgrounds {
            view.alpha = 0.0
        }
        UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseInOut], animations: {
            for view in backgrounds {
                view.alpha = 1.0
            }
        })
        // v24: кнопки проявляются, когда картинка аватарки уже есть. Раньше стекло кнопки появлялось пустым кругом,
        // а фото проступало на 2–3 кадра позже — шапка «мелькала».
        let avatarImage = (chat.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.avatarNode.contentNode.imageNode
        avatarImage?.enableAnimatedTransition = false
        let start = CACurrentMediaTime()
        func fadeIn(_ views: [UIView]) {
            // v26: как в родном — прозрачность и размытие вместе (было: 0,15 с только прозрачность, резко).
            let duration = ConceptsTopicSwipeTune.v("ctlDur", 0.3)
            let radius = ConceptsTopicSwipeTune.v("ctlBlur", 10.0)
            for view in views {
                if radius > 0.0, let blur = CALayer.blur() {
                    blur.setValue(0.0 as NSNumber, forKey: "inputRadius")
                    view.layer.filters = [blur]
                    view.layer.animate(from: radius as NSNumber, to: 0.0 as NSNumber, keyPath: "filters.gaussianBlur.inputRadius", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: duration, removeOnCompletion: false, completion: { [weak view] _ in
                        view?.layer.filters = nil
                    })
                }
            }
            ConceptsTopicSwipeMotion.standard(duration, {
                for view in views {
                    view.alpha = 1.0
                }
            })
            // v32: лёгкий баунс — кнопки вырастают из ctlScale с небольшим перелётом (пружина ctlStiff/ctlDamp).
            let fromScale = ConceptsTopicSwipeTune.v("ctlScale", 0.8)
            if fromScale < 0.999 {
                for view in views {
                    let bounce = CASpringAnimation(keyPath: "transform.scale")
                    bounce.fromValue = fromScale as NSNumber
                    bounce.toValue = 1.0 as NSNumber
                    bounce.mass = 1.0
                    bounce.stiffness = ConceptsTopicSwipeTune.v("ctlStiff", 420.0)
                    bounce.damping = ConceptsTopicSwipeTune.v("ctlDamp", 22.0)
                    bounce.duration = bounce.settlingDuration
                    bounce.isRemovedOnCompletion = true
                    view.layer.add(bounce, forKey: "conceptsTopicSwipeBounce")
                }
            }
        }
        // v29: кнопка-аватарка ждёт фото отдельно, остальные кнопки — нет. Собранный заранее чат при входе в окно
        // перерисовывает фото: картинка есть, пропадает на 3–5 кадров и появляется снова — пустой круг стекла.
        // Ждём, пока фото простоит 4 кадра подряд (не дольше 0,4 с).
        let avatarView = chat.chatInfoNavigationButton?.buttonItem.customDisplayNode?.view
        let avatarControls = controls.filter { control in avatarView.map { $0 === control || $0.isDescendant(of: control) } ?? false }
        let otherControls = controls.filter { control in !avatarControls.contains(where: { $0 === control }) }
        func showControls() {
            // v28: проявление шло поверх паузы подмены чата (≈0,14 с) и выглядело рывком — ждём подмену (ctlWait; v29 — 0: паузы больше нет).
            if ConceptsTopicSwipeClock.chatOpenedAt < ConceptsTopicSwipeClock.openStartedAt, CACurrentMediaTime() - start < ConceptsTopicSwipeTune.v("ctlWait", 0.0) {
                Queue.mainQueue().after(1.0 / 60.0, showControls)
                return
            }
            ConceptsTopicSwipeAutopilot.mark("navControls|\(Int((CACurrentMediaTime() - start) * 1000.0))")
            // v50: из списка все кнопки и подпись проявляются одним ходом — вместе с аватаркой (showAvatar).
            if !self.openedFromList {
                fadeIn(otherControls)
            }
        }
        var stableFrames = 0
        func showAvatar() {
            if let avatarImage {
                stableFrames = avatarImage.layer.contents == nil ? 0 : stableFrames + 1
            } else {
                stableFrames = 99
            }
            if stableFrames < 4, CACurrentMediaTime() - start < 0.4 {
                Queue.mainQueue().after(1.0 / 60.0, showAvatar)
                return
            }
            ConceptsTopicSwipeAutopilot.mark("navAvatar|\(Int((CACurrentMediaTime() - start) * 1000.0))|\(avatarControls.count)")
            fadeIn(self.openedFromList ? controls : avatarControls)
        }
        // v29: старт на следующем кадре, не в том же такте, что встраивание: из списка кнопки иначе мелькали целиком на 1 кадр.
        Queue.mainQueue().after(1.0 / 60.0, {
            showAvatar()
            showControls()
        })
        ConceptsTopicSwipeAutopilot.mark("navFade|\(controls.count)|\(backgrounds.count)")
    }

    private var openedFromList = false
    /// Когда панель встаёт в чат (от подстановки чата): из списка — после въезда, иначе подписи двоились на ходу.
    /// v30: раньше (embedDelay/embedDelayList) — кнопки шапки проявлялись с запозданием.
    var embedDelay: Double { return self.openedFromList ? ConceptsTopicSwipeTune.v("embedDelayList", 0.3) : ConceptsTopicSwipeTune.v("embedDelay", 0.12) }

    func animateZoomOpen(peer: EnginePeer, bottomInset: CGFloat? = nil, completion: @escaping () -> Void) {
        self.finishPendingFlip()
        self.isUserInteractionEnabled = false
        self.cardShadowIsAnimatingOpen = true
        // Из списка открывается любой чат: подставляем его предпросмотр; сначала гаснет список, затем проявляется
        // предпросмотр — строки не ложатся поверх сообщений.
        let wasPrepared = self.preparedPeers.contains(peer.id)
        let z0 = CACurrentMediaTime()
        ConceptsTopicSwipeClock.openStartedAt = z0
        func zmark(_ name: String) {
            ConceptsTopicSwipeAutopilot.mark("zoom|\(name)|\(Int((CACurrentMediaTime() - z0) * 1000.0))")
        }
        self.showPreview(for: peer, animated: false)
        zmark("show")
        // Остальные собранные заранее предпросмотры (1 %, позади) при раскрытии не нужны: их отрисовка на каждом кадре
        // раскрытия роняла частоту кадров вдвое.
        for (_, preview) in self.previews where preview !== self.currentPreview && preview.isNodeLoaded {
            preview.displayNode.view.isHidden = true
        }
        let wasList = self.listContainer.alpha > 0.5
        if wasList {
            // Собранный только что предпросмотр ещё без разложенной шапки (подпись слева) — тогда карточка раскрывается
            // без шапки. Собранный заранее (`prewarmPath`) раскрывается с шапкой, как из ряда.
            if !wasPrepared {
                self.currentPreview?.navigationBar?.view.isHidden = true
            }
            // v22: карточка со списком раскрывается в чат так же, как с предпросмотром; меняется только содержимое —
            // список гаснет с размытием, чат проявляется из размытия (v21 — въезд справа, не то).
            // v50: капсула предпросмотра скрыта — подпись проявится в настоящей шапке разом с кнопками.
            self.nativeTitle(self.currentPreview)?.alpha = 0.0
            // Список на время перехода — неподвижный снимок поверх чата: живой при раскрытии карточки перекладывался
            // (прокрутка упиралась в новый размер, строки прыгали).
            // v25: гаснет сам список, без снимка — снимок стоил ≈50 мс в первом кадре, и список пропадал рывком.
            // Рамку списка раскрытие не меняет — строки не перекладываются.
            let list = self.listContainer
            // v28: рамка прокрутки растёт вместе с карточкой и упиралась в конец списка — строки прыгали на одну вниз.
            // Запас снизу на высоту экрана: сдвиг прокрутки остаётся прежним.
            // Карточка доходит до верха экрана — система добавляла прокрутке отступ под строку состояния (сдвиг на строку).
            let listOffset = self.listScroll.contentOffset
            self.listScroll.contentInsetAdjustmentBehavior = .never
            self.listScroll.contentInset.bottom = self.bounds.height
            self.listScroll.contentOffset = listOffset
            if let blur = CALayer.blur() {
                blur.setValue(0.0 as NSNumber, forKey: "inputRadius")
                list.layer.filters = [blur]
                list.layer.animate(from: 0.0 as NSNumber, to: 14.0 as NSNumber, keyPath: "filters.gaussianBlur.inputRadius", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.25, removeOnCompletion: false)
            }
            ConceptsTopicSwipeMotion.ease(0.25, {
                list.alpha = 0.0
            }, completion: {
                list.layer.removeAllAnimations()
                list.layer.filters = nil
            })
            zmark("snap")
            // Чат сразу под списком (размытый) — в середине смены карточка не бледнеет до белого.
            self.previewHost.alpha = 1.0
            if let blur = CALayer.blur() {
                blur.setValue(0.0 as NSNumber, forKey: "inputRadius")
                self.previewHost.layer.filters = [blur]
                self.previewHost.layer.animate(from: 14.0 as NSNumber, to: 0.0 as NSNumber, keyPath: "filters.gaussianBlur.inputRadius", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.35, removeOnCompletion: false, completion: { [weak self] _ in
                    self?.previewHost.layer.filters = nil
                })
            }
            ConceptsTopicSwipeMotion.ease(0.15, {
                self.headerTitle.alpha = 0.0
            })
        } else {
            self.previewHost.alpha = 1.0
        }
        let full = self.bounds
        let duration: Double = 0.5
        let transition: ContainedViewLayoutTransition = .animated(duration: duration, curve: .customSpring(mass: 1.0, stiffness: 440.0, damping: 42.0, initialVelocity: 0.0))
        ConceptsTopicSwipeMotion.ease(0.3, {
            self.rowContainer.alpha = 0.0
        })
        if !wasList {
            ConceptsTopicSwipeMotion.ease(0.12, {
                self.listContainer.alpha = 0.0
            })
        }
        self.openedFromList = wasList
        let cornerRadius: CGFloat = self.layout.deviceMetrics.screenCornerRadius
        transition.updateFrame(view: self.cardShadow, frame: full)
        transition.updateFrame(view: self.cardClip, frame: CGRect(origin: .zero, size: full.size))
        transition.updateFrame(view: self.previewHost, frame: CGRect(origin: .zero, size: full.size))
        // v26: углы карточки за время раскрытия становятся углами экрана (явная пружина: через переход радиус
        // менялся не вместе с рамкой). openCorner — подстройка радиуса.
        let targetCorner = CGFloat(ConceptsTopicSwipeTune.v("openCorner", Double(cornerRadius)))
        if #available(iOS 13.0, *) {
            self.cardClip.layer.cornerCurve = .continuous
        }
        let corner = CASpringAnimation(keyPath: "cornerRadius")
        corner.mass = 1.0
        corner.stiffness = 440.0
        corner.damping = 42.0
        corner.fromValue = (self.cardClip.layer.presentation()?.cornerRadius ?? self.cardClip.layer.cornerRadius) as NSNumber
        corner.toValue = targetCorner as NSNumber
        corner.duration = corner.settlingDuration
        self.cardClip.layer.cornerRadius = targetCorner
        self.cardClip.layer.add(corner, forKey: "cornerRadius")
        self.cardShadow.layer.shadowOpacity = 0.0
        // Предпросмотр получает раскладку настоящего чата: шапка и сообщения встают туда же, где будут после открытия.
        // У предпросмотра нет панели ввода: отступ снизу как у настоящего чата (до верха панели), иначе при подмене сообщения «двоятся».
        var insets = self.layout.intrinsicInsets
        insets.bottom = max(insets.bottom, bottomInset ?? self.inputPanelHeight)
        zmark("preLayout")
        self.layoutPreview(self.layout.withUpdatedIntrinsicInsets(insets), transition: transition)
        zmark("layout")
        // Капсула шапки едет вместе с раскрытием к месту и ширине родной (её рамка уже конечная), затем перетекает в неё.
        if !wasList, let native = self.nativeTitle(self.currentPreview), let pill = native.glassPillFrame {
            let target = native.convert(pill, to: self.cardClip)
            // v22: и место, и ширина — пружиной раскрытия, без отскока: с отскоком ширина капсулы «дрыгалась».
            self.headerTitle.morph(to: target, transition: ComponentTransition(transition), positionTransition: ComponentTransition(transition))
            native.alpha = 0.0
            ConceptsTopicSwipeMotion.ease(0.15, delay: 0.2, {
                native.alpha = 1.0
                self.headerTitle.alpha = 0.0
            })
        } else if !wasList {
            self.nativeTitle(self.currentPreview)?.alpha = 1.0
            self.headerTitle.isHidden = true
        }
        // Пружина к 0,3 с почти у цели (≈1 pt): настоящий чат подставляется сразу (v16: было 0,4 — элементы шапки
        // появлялись с заметной задержкой).
        Queue.mainQueue().after(0.3, {
            completion()
        })
    }
}

// MARK: - Recording hooks

/// The scripted run used for the video (real touch events, timing marks) lives in a private test bench and is not
/// included; the gesture code only reports timing marks here.
enum ConceptsTopicSwipeAutopilot {
    static let isRecording = false
    static func mark(_ name: String) {
    }
}
