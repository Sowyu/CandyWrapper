import AppKit
import DesignSystem

/// What the T3 Connect sign-in sheet shows. The app fills it from `T3ConnectSignInFlow`.
public struct T3ConnectSignInModel: Equatable {
    public enum Step: Equatable { case email, code(sentTo: String), password }
    public var step: Step
    public var email: String
    public var busy: Bool
    public var resending: Bool
    public var error: String?
    public var notice: String?

    public init(step: Step = .email, email: String = "", busy: Bool = false, resending: Bool = false, error: String? = nil, notice: String? = nil) {
        self.step = step; self.email = email; self.busy = busy; self.resending = resending; self.error = error; self.notice = notice
    }
}

/// The sign-in sheet: T3 opens Clerk's sign-in modal here (`clerk.openSignIn`). Clerk's production keys
/// only load on T3's own domains, so there is no capture of it; this follows Clerk's stock English copy
/// (card titles, "Email address", "Continue", "Use another method") inside CandyWrapper's Dialog.
/// Email code and password only; social buttons and passkeys are left out (PROGRESS.md, Decisions made).
public enum T3ConnectSignInDialog {
    /// Clerk's `applicationName` from T3's instance (`display_config.application_name`).
    public static let applicationName = "T3 Code"

    public static func make() -> (dialog: DialogView, form: T3ConnectSignInFormView) {
        let dialog = DialogView(title: "", message: nil)
        // Clerk's card is `25rem` wide.
        dialog.maxWidth = 400
        let form = T3ConnectSignInFormView()
        dialog.panelContent = [form]
        form.onStepChange = { [weak dialog] step in apply(step, to: dialog) }
        apply(.email, to: dialog)
        return (dialog, form)
    }

    static func apply(_ step: T3ConnectSignInModel.Step, to dialog: DialogView?) {
        guard let dialog else { return }
        switch step {
        case .email:
            dialog.title = "Sign in to \(applicationName)"
            dialog.message = "Welcome back! Please sign in to continue"
        case .code:
            dialog.title = "Check your email"
            dialog.message = "to continue to \(applicationName)"
        case .password:
            dialog.title = "Enter your password"
            dialog.message = "Enter the password associated with your account"
        }
    }
}

public final class T3ConnectSignInFormView: DSView {
    public let emailField = InputView(placeholder: "Enter your email address")
    public let codeField = InputView(placeholder: "Enter the 6-digit code")
    public let passwordField = SecureInputView(placeholder: "Enter your password")
    private let emailLabel = LabelView("Email address", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    private let codeLabel = LabelView("Verification code", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    private let passwordLabel = LabelView("Password", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    private let identity = LabelView("", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private let edit = ButtonView(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs)
    private let message = TextBlockView()
    private let resendPrompt = LabelView("Didn't receive a code?", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private let resend = ButtonView("Resend", variant: .link, size: .xs)
    public let submit = ButtonView("Continue", variant: .default)
    private let otherMethod = ButtonView("Use another method", variant: .link, size: .xs)

    public private(set) var model = T3ConnectSignInModel()

    public var onSubmitEmail: ((String) -> Void)?
    public var onSubmitCode: ((String) -> Void)?
    public var onSubmitPassword: ((String) -> Void)?
    public var onResend: (() -> Void)?
    /// "Use another method": password from the code step, an emailed code from the password step.
    public var onOtherMethod: (() -> Void)?
    public var onEditEmail: (() -> Void)?
    public var onHeightChange: (() -> Void)?
    var onStepChange: ((T3ConnectSignInModel.Step) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [emailLabel, codeLabel, passwordLabel, identity, resendPrompt] { l.lineHeight = 16 }
        identity.truncates = true
        message.font = DSFont.ui(12)
        message.lineHeight = 16
        edit.iconSize = 12
        edit.setAccessibilityLabel("Edit email address")
        TooltipController.attach(to: edit, text: "Edit")
        for v in [emailLabel, emailField, identity, edit, codeLabel, codeField, passwordLabel, passwordField,
                  message, resendPrompt, resend, submit, otherMethod] as [NSView] { addSubview(v) }
        submit.action = { [weak self] in self?.submitNow() }
        emailField.onSubmit = { [weak self] in self?.submitNow() }
        codeField.onSubmit = { [weak self] in self?.submitNow() }
        passwordField.onSubmit = { [weak self] in self?.submitNow() }
        // Clerk's code field submits by itself once six digits are in.
        codeField.onChange = { [weak self] text in
            guard let self, !self.model.busy, text.filter(\.isNumber).count == 6 else { return }
            self.onSubmitCode?(text)
        }
        resend.action = { [weak self] in self?.onResend?() }
        otherMethod.action = { [weak self] in self?.onOtherMethod?() }
        edit.action = { [weak self] in self?.onEditEmail?() }
        set(model)
    }

    /// The field the current step types into.
    public var focusTarget: NSView {
        switch model.step {
        case .email: emailField
        case .code: codeField
        case .password: passwordField
        }
    }

    public func set(_ next: T3ConnectSignInModel) {
        let stepChanged = next.step != model.step
        model = next
        let step = next.step
        let isEmail = step == .email, isPassword = step == .password
        var isCode = false
        if case .code(let sentTo) = step { isCode = true; identity.text = sentTo } else { identity.text = next.email }
        emailLabel.isHidden = !isEmail
        emailField.isHidden = !isEmail
        identity.isHidden = isEmail
        edit.isHidden = isEmail
        codeLabel.isHidden = !isCode
        codeField.isHidden = !isCode
        passwordLabel.isHidden = !isPassword
        passwordField.isHidden = !isPassword
        resendPrompt.isHidden = !isCode
        resend.isHidden = !isCode
        otherMethod.isHidden = isEmail
        if isEmail, emailField.text.isEmpty { emailField.text = next.email }
        // A refused or resent code empties the field, as Clerk's OTP input does.
        let codeFailed = isCode && (next.error != nil || next.notice != nil) && !next.busy
        if stepChanged || codeFailed { codeField.text = "" }
        if stepChanged { passwordField.text = "" }
        let text = next.error ?? next.notice
        message.text = text ?? ""
        message.isHidden = text == nil
        message.color = next.error != nil ? Themed.color(\.destructive) : Themed.color(\.mutedForeground)
        emailField.isInvalid = isEmail && next.error != nil
        codeField.isInvalid = isCode && next.error != nil
        passwordField.isInvalid = isPassword && next.error != nil
        for f in [emailField, codeField] { f.isEnabled = !next.busy }
        passwordField.isEnabled = !next.busy
        submit.isEnabled = !next.busy
        submit.title = next.busy && !next.resending ? "Continuing…" : "Continue"
        resend.isEnabled = !next.busy
        resend.title = next.resending ? "Sending…" : "Resend"
        otherMethod.isEnabled = !next.busy
        edit.isEnabled = !next.busy
        if stepChanged { onStepChange?(step) }
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChange?()
    }

    func submitNow() {
        guard !model.busy else { return }
        switch model.step {
        case .email: onSubmitEmail?(emailField.text)
        case .code: onSubmitCode?(codeField.text)
        case .password: onSubmitPassword?(passwordField.text)
        }
    }

    // Layout, `gap-6` between Clerk's card sections, `gap-2` inside a field: the identity row, the field
    // (label, then a 32pt input), the message, the resend line, Continue, then "Use another method".
    private func frames(width w: CGFloat) -> (rows: [(NSView, NSRect)], height: CGFloat) {
        var rows: [(NSView, NSRect)] = []
        var y: CGFloat = 0
        if !identity.isHidden {
            rows.append((identity, NSRect(x: 0, y: y + 4, width: min(ceil(identity.textWidth) + 1, w - 28), height: 16)))
            rows.append((edit, NSRect(x: min(ceil(identity.textWidth) + 1, w - 28) + 4, y: y, width: 24, height: 24)))
            y += 24 + 16
        }
        let label: NSView = !emailField.isHidden ? emailLabel : !codeField.isHidden ? codeLabel : passwordLabel
        let field: NSView = !emailField.isHidden ? emailField : !codeField.isHidden ? codeField : passwordField
        rows.append((label, NSRect(x: 0, y: y, width: w, height: 16)))
        y += 16 + 8
        rows.append((field, NSRect(x: 0, y: y, width: w, height: 32)))
        y += 32
        if !message.isHidden {
            y += 8
            let h = message.height(forWidth: w)
            rows.append((message, NSRect(x: 0, y: y, width: w, height: h)))
            y += h
        }
        if !resend.isHidden {
            y += 12
            let pw = ceil(resendPrompt.textWidth) + 1
            let rs = resend.intrinsicContentSize
            rows.append((resendPrompt, NSRect(x: 0, y: y + (rs.height - 16) / 2, width: pw, height: 16)))
            rows.append((resend, NSRect(x: pw + 2, y: y, width: rs.width, height: rs.height)))
            y += rs.height
        }
        y += 20
        rows.append((submit, NSRect(x: 0, y: y, width: w, height: 32)))
        y += 32
        if !otherMethod.isHidden {
            y += 12
            let s = otherMethod.intrinsicContentSize
            rows.append((otherMethod, NSRect(x: ((w - s.width) / 2).rounded(), y: y, width: s.width, height: s.height)))
            y += s.height
        }
        return (rows, y)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? frames(width: bounds.width).height : 120)
    }

    public override func layout() {
        super.layout()
        for (view, frame) in frames(width: bounds.width).rows { view.frame = frame }
    }
}
