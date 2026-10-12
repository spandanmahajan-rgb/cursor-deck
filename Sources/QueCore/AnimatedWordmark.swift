// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import SwiftUI

/// The "que" wordmark split into its five shapes, for the welcome animation: the q's dot drops into a "u" (the q turned
/// so its notch faces up) and, the instant it touches, its weight rolls the letter round into the q. Frames are in points for
/// the 190 pt wide wordmark (origin top-left); images are 3x template PNGs (coloured by the view).
enum WordmarkPiece: CaseIterable {
    case qBody, qDot, u, eBody, eDot

    static let size = CGSize(width: 190.000, height: 58.432)
    /// Centre of the q's circle: it rolls around this point.
    static let pivot = CGPoint(x: 28.955, y: 29.216)
    /// How far the q rolls (clockwise, degrees) from "notch facing up" to its real position.
    static let rollAngle: Double = 145.72

    private var source: (base64: String, frame: CGRect) {
        switch self {
        case .qBody: return ("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", CGRect(x: 0.000, y: 0.000, width: 58.562, height: 58.432))
        case .qDot: return ("iVBORw0KGgoAAAANSUhEUgAAAC8AAAAuCAYAAAC4e0AJAAADUElEQVR42tWaO2gUURSGv5lN4SsaNeALo4IaVLRQsBBEAwqCEewECxtRC1sRm6BFsEmlFhZiIxZWFrHxUQgKKiksNKKF+EAhPlDiI2KyuzMWOSccxjvJPmZ37l64zM7u3rn/+c+5555z7hSorwVAQXpcxbg2GVv35LWOC4Fy4vtOYBXQBcwCZgPjwF9gBHgLfAYiM0YFj2hCKySE2AkMAA+BHwIkrf8BngKXgV6gPWttpLXQPHw+cFKAuECWgRJQlGs55X/vgPPA6hRyMmf7mKg/NupWkJH0NOYjEaSYEOg70C+kZCqAPmgdcNdMOB2jlXYVRO9fAj1m3rrMqE2uvcDXDEG7NFI0Ap1ymGpNwE8YsKWMQbs0oXNdqFUDCvy446GN7lYLl6r1RGrj+wzoZgF3CXCm0kWsNtYFfDHeIc6hR8ZM91YigIK/3SQbr2QNRMB7YJHgC6czl8MysJgz8DiB42Ia+4H0OcDrnM0lbWMbBzaZuOo/73LUE3NJY/+Ki31lfiixUGKP2I+AUWCpYg5NSLoN2Nqo4CiD0D0CFgAHFaPdfvcL6DJ+NtXCAb0PTRKwq84EpRl5RABsl+izrODbgQ3G1/vYAmG+E+i2QJcDS/C/qZWst+BXGsmCFgC/zIJfnPgRj01nCm+Y2KRapcUWfNRi4EMLftRzT5NsvyzYTwl35HsbseA/Ar9bALSGLW9s8vENeOW5/asbH5MSCRqYRRJR4rHZKKnPJEUNQgN20PNFqzjvyOeCdfxzpYznUxaVjOknJJuaColVijHguomdfWoapt8HXiTL67pwV4jPn6lgmkcVIZZakjNZ0i/6PaseaEp6z5V8W/ZDYJ740dgD29d8ehzYMpNDUfb3GPbzNJ8JuZ6uNLfWP/QlHpBXueOmObibMdcIjABXcxJA53skKWpQTZKkAoTANbNwoiZWhx8DC2stCtiVPeBQZyO8ipIzCHTUu+NbdR2RAM56gSgjH14yxJw1c4ZkdMoNsBa44VhY5SoEsSeCdswDYIeDtMyPM3cDtxz7QGSYLDk+u/aNIeCQAVtoZO5oVbkZOAc8AX5W4UmGmTww60kwHDbj3QPX+wLdwEbZCddISa6DySP7UeCDBFXDwPNETbSmGuk/A45+d+kgyUoAAAAASUVORK5CYII=", CGRect(x: 35.918, y: 43.075, width: 15.747, height: 15.356))
        case .u: return ("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", CGRect(x: 62.596, y: 2.212, width: 62.856, height: 55.308))
        case .eBody: return ("iVBORw0KGgoAAAANSUhEUgAAAKsAAACvCAYAAACCeS4PAAAPsklEQVR42u2da4wdZRnHfzNnW1oWocXSFiiwXIpQrFwLFOUiSIQAIiISSYAEuX2QKAqo0UQ+EFECkUhCIqhEUDBeAIlC0GLlVgQKLVAuUkAo0NJCobCF1u6eM35439d9+3bm7J7t2TMzZ/5P8mZPT7fdszP/eZ7/c4+QOImA2H5NgHrG920D7ABMAWYA2wPTge2AXmBb++8nApPs6wRYDTSADcB7QD+wEngLeMO+XgWsANZn/Owe+zWx/1dStRtUZXA6gDbs8WUisDOwD7AXMAuYCUz1gNlueRd4xwL4OeAF+/VZC+bwAarZr5UAbhXB6rRneOMnAfsCc4FDgdlAn/3+NEk8gCQtXtMk+N5omH+3DlgKLAYeAp4EngYGgt8r68ETWEsG0BgYDN7fGzjGnkOsSQ/F3fyoBXCNVpLgOO2Z9rOWWuDeB9xvqURIabpK43YzWN0NSwJNcyBwAnAicIBnSkNzGo0hKEcLYvfQ1IK/7wceAe4E7gVeCahC0q3athtA2hO8txtwCfCoNf++9hqwGreRotmKehr293Cf3f+7fuAe4GzLrRlGQ0tyMvW+xhkHnAT8EVgb3NBBe7PLBNDhwDtoweu/vwK4xnJv/zpJCgLSacDFwDNdDtDhgDsYhM2+B4wPogiSDpp7/6LvYbXIKu8m1Uto4tsNXF/bPmTDbwJsTpy0z4J0TYoWTXT+D9oN9vUq4HABduzFv7jTgauBDwJnqSFwZh5HDT4SYMc+TgowwXr2ywXSzQLsKkud5HS1UXyTfwKwKLjwAunoAfsYJq2ssFYbtenOwG8E0rYe53j9QHSgfdz0a5giDufdy3Fqb2Kh3zqpkejA6D39GcAdKaZLp/3a9afSrq2bfSenYAozZPLHXrs2gLcxdbiIu47c7PfYmKm0aeedrdNTHFpJhre/KzBf3DQXKtAAbhEVGBk/Pdoz+wMCUEePUwovSKs2rzUFOI+hVKDMfj68NcFUpvUVOUkQ51jw3QCuAG7AlPM1ZIJyUxwJpqdsxyI7WT05PBwOlDcA51gzFCvGl6u4e9JLSVKZnQLqOExB9Bes2VeqrziSlCW22Qmgbo3pE3JA7RFQ1ZNXJM3qgLoN8BfgMx5QJcUC6YYqa9bIAnUL4HYL1AEBtXCmP7ZAXVlkOhB3YOLJeMtRj7YadZzwUUie+jawrIpg9Ycs3ITp0ZfpLzZYnwI+9GYtVAasNUxI6lrgDAG1FGCdV8WuAQfKb6rlpDRVV+uoYIuLy0CdhMr7ylTPekdVgToLeN+rRBcoij0MI8EMpatMxZVzqLYGlqgopVRa9baqaVXHU29RmV9pygJdh8COVarNcKbjAgG1dCOFTq6S+Xe/5GzrUdblUBVeozp6dlnVeGoNk6FaGFSd6xS31yoBvl+1fiv3i14hh6rw2nTAGzR8ZtV6rdwvOqekk6Orokl9BfIPS9cqBVTf/D8m819IkPr34xngLK8MsFKtQ7UgnSrzXxxzXw806Vcw5ZlUMe/vdkjtZLNU6u8vnvM0DzguRcFEVZ2ccrO0auFSpq95zpNP16Iqj/iZG8TrdPKtmEqAWzGTwMnYk0VVB6fdL61amCkqG4CLcmytL7RWPUFALQxQ3wU+p4Vs6Vq1B7PgVmDNH6ivAwdJm2Zr1S8rploYjbofQ1sUJSkb/BYG3qdO573+9cBR0qjNtepx0qqFiKOeI6AOHwG4V1w1d6D+UkAdHqgHBDE9nc5X9L+MaRmKq+z1xyOYf3ShfV3X89txSey1/zpm7WdU9El/5Dioa7r1PsVX8zP/d2rWf3PN6i7MqcBkb+CvpLPD0urA5Qr4Nwdr3V6gM2V2yGsSdYSZvLhYNGx4AO/vEXw5V/k4VoepMKW5ZnXvne6ZIpmhzomjXAuBR7z3BNaMizUOM0pdu+jzk1utlpVWzQBizV6gg4C9PKIvoaNZwwHgbo+/SlKAGHlTAEXq83GswMwLe9kbcy8JwBp5/PRYUYBcwbrA3gtRgCZgTYCZwL5a502eyZhHKcFeqjzB6l4fYR2sQYE1l/vhlv5KmoDVPcWf1WUhzzqANcCbcq6ywer46kSGpiCLr+aziKIfMzdV0gSsYJYg7Cqw5grW1ZjQlSqsMsDqvh7sZa0k+ciHugTNwZp49QDyQilEK5EkA6wNT7MqZEUhYq2SjEFrCaZudRfxVfKOsU6SdcsGqwPm7sAUL4QiyQes27DxmEpJoFkBdvOWA0vyk0nADrJwzZMCe8v85K5ZE2ArzG4q+Q5NwDpTl6MwztUsXYp0sLqY6g56milKYuAw3YvswonxwPa6QIWxdHPtPVExUcrF2YqNJydL8lUeezJUpiknK7gQW9sjoRANgwBflPJIB+sUPcGFuyenYeKt6i5O0awoIVAop3cmcLyaNjcF67YoL11EuVix703BqnHfFK7yqgEcDhxjX2swG0P5aD3BFDKrdSUaILwRWCcIrIXlrnOA89SavWnxtaR496cB/AjTblTp0aPyMstR3DIJs1OgVuVR7QJrOZytOqZF/kpMCrZHDYOSIgN2ELgUuADT/TquqmDtV2qvNOGs6zHZrYGqadg4aP8VWIvNX925DTjDatvKLBl2YF0nsJaqTysGfgt8y9uiU6sKWNcIrKUDbAO4Bvg5psSzbmlBVCALELXz86SBVTHX8lCCOnA+8DBwpLc7q5Ogje3Pq3n4CU/NO5v9uWYAGxjawKyNKeVb7la3mnZq4JTFY/SwZAFvK2AapvNkcoYTOKrPFXklgkvtL9pQKIsyNhq6e7YcuA74BfBOAC5fEY1Gk8feg+FkH6vV52IG+03D1JrUrOP+rv1MjwP3WyvwURDhSFoNizyltZddo2UT4HXgJ8DsYUy3f+Lgzz0ZmnEqZp38P4H/tvgZX8EkN3YfzXwv90T+TWvau+I0gns4YDXaZZhZZluOkpf22XDZbcBbwc8csD9zMFj017B/HrTf4yvCfuDHDI1Lqo1EvffY/+wGTHXPoErS6Ja27nrKvXwNsw3mReDfwBvAexZMAxbMEzGDNvqsaZ+NWTU1gU17xVqtVXAgdp/rReAiqyzj4WiK+0eXSrN2taYdaBPNGGyTE97wPlMD+MZwGtYPN3wc+Kp6froyzBUHWquR4WxF3vu+KQ8H+UVt/FxOQx+PqXe4zyrQRjOwjgPOVYtLJeKzcXD84H3a97Q1uJ/hM9WBozDZ1AfTABt5YJ1g+cNOCl9JcubYJwN3eeWRG00AiYH1lnCrc0CSJ11JrLM/PVSaYT3rEwKrhPz7zqZhYsRJsx6sx1WMLaEYdbtnAof6beghWBdaOiCwSvKkAw379ds+Pv1tLREmRbckCPpKJHlo1wQTztrFcdc4Rf0+It4qKYh27QVOdNQ0zdzfp0JsCcUJZ33evY5T5tkvwBRj16RdJQVIYMzG1CrU45SayLcxNYeaKigpQvvOTphQ1iZev0ut/VXXSlKQaTQ17L6LOKV8KwHuxlRziwpIiiC9WWCNMTWPC7zqG4mEIs66cu/9XhEBSUFkfRZYXTLgLuB9UQEJ+YWtXLx1eRZYHald6TlaogKSvGSFxeKwNQC/UoJAQr57bJdgWrrjuMnisAh4AHjGm/4hkXR6j+38ZulWvFqBAeBGaVZJDkB1+LsrLd2a5WjdislqxeKukg5TgPnA864oOx4BulcDN3memURCh+oCrvN9pmiEW5p3sdy1Vw6XhLFftFwDngQO8aa4DBsNcBmtV4GbpV0lHSxgccs+YlrQkE679lntuqW0q2QMtWoMLMLM5fInuIyo18pp1/8Av1YYS9KhFaD1cLh11EINQYIZOrwEMzB2LKd0SKrLVR8FPp1WRFVrMe61BlO1fZSmtkjGSKuejZnhGoc1KdEowgkfAxbbCIGGuEnaqVVvB04Nxwa1PHHYowPrMLHXL0m7SmhPtirBTNA+DTPWPbW7Oh5FZqGG2cE0P+sJkEhGgamrMIMBMzOl0WasFZ+NmeBS6U3NkraY/+eBA4P9BGwuDfCdrbcsSI8WHZBshvmPgdMx24LGpP7EjSfcAhPA1Xh3nVaPG9H+s1YWYLAZ/VsNYH/gX6IDklGY/6UWP+tG0pFSa0PN4XL7w4/10mUSyXDmP7Fhqpc6VXPir0XUHi2dVsz/D1tVmFGb2rkbmL1JT2BGvcjhkjQz//MwA9eiVtZhxm2Mk70JnLUZ+0ElVCKe+obFSdIqTmq0j4f0WMK8zj414q+SkKfWMZtYnvXmAZPnxGIwhdpJm7ba6ZR/w6HDwYVsvNWSIqyHmYBp4xZgddz9v7pIQA158DTMXi1FCATUPwQbLSkiYPe2jpcAW12gzsfUQBc6YeT468GYAW9JsG9ep3uPU0yLgG3LslvN8ZMjgA+kYSulURe58epligo5wB4pDVsZoL6E2QXQzvCoNKxO24H6JKaxtJRATdOwqwXYrjf9pQVqCNj9gGWKw3bF2WC/zgMmdwtQQ8D2eYXbAmw5M1POMv7OJoK6cqO6e/ImY+ZvOkrQEAhKcXwH+ao2F0YVGrA14NqMC6FT3BjqeuDcYNkf3b7ayP2S5wFrRQtKYfZfxoz4KWwKday7DVy26znRgkKafXcv/gxMLWJRSh6O1yTMlphE4a1ChaUGgO+OQS106XkswBmY2QQOsOKy+WnTxZ7Zj1VUn04L+oA/BU+5qEHnuOkgpg61V9p0ZLQATM/OMlGDjnn6CfC4TY/L7LcQLXAmZzpwvXdB66IGYwLS1cAlwPgqevvt5rKH2dReIj7bFpDWvYf/JmA3adP2clkwszyfEmhHDVKf+98DzA1AKm3a5kTCeOAczBYZ34sVp812nHyQ3otpm/dBKk9/jKnBROD8QNM2lFjIfHjnAceldCVLOkgNejDDvualmL0qAbeRQovWYiaWHx5YKfHSnEGLDWLfiFmSHGZk6l0I3Ib3UPrvLwUuB/YY5npJcgKt7xxsj5kE8kCKAzZQco1bzwDoGkyv/ikMbYR01EkgLagjFt6YTwLfARakVHbVSwBeB860TN4H1mG6kKEeKJ8exd2y1LUK2rYeTKz7FGYfwvHAHIZaMvCm3jkg+A5IJ65ZCNIoo2b0deBh4O+Wpy9LcUBHPFJSYC1mRmwweH8acBBmc+KhwCeA7cge3dgIrl/U4jVNUl4nI4hxvolZR/qgpTVPY9rbwwfT/4xdty67yqnctBs7BZiFWZ80B9gT2N2+3wlzOoipOHsRMy/sCQvSZ61XT0oAvysBKrBmTz+MUugCXp3tVOtVz8BM+p5htfJUTGXSROvQRJYn9nr/11oPUB9i2kLWWlCutCZ9BWZv6as2irG2yUOWdJOJF1jbA15SaAMZSYpehjaGj8PsucVzgBr2Yei3gE1aKOSpHDhD+R9i1+w1meHfHAAAAABJRU5ErkJggg==", CGRect(x: 129.226, y: 0.000, width: 57.130, height: 58.432))
        case .eDot: return ("iVBORw0KGgoAAAANSUhEUgAAAC4AAAAvCAYAAACc5fiSAAADKklEQVR42tWZv2sUURDHP7t3IPF3YoREiT8QLFKIhYSk0UBELGwiBNKKTSo7sbKxsvEvsJAUYmEhBlQStFKMhdqoiKBBI3JBgz8SYiS5u7VwJoyPvcvd3u7l3cBwx9693e/77rz3Zr6TozELgJx4uY5xoYwBiJI+OOm4ECg517qBQ8B+YJe5vgoUgBngE/DDmUTg3CsTyzkPPQFcA54Dv4XBaj4PTAEXgd4YMlK30Nx4CzAGvIwBVgaKwvIqsCKfpZj/LgN3gTMViEmV5XPAeweoAiuvw3bZTKzo/DYJ9KXJvoLeB0yYBxUrsFiPu5MoAlcM6MTg8/J5EviSIuA4L5o3Ngl0JQ0dBT0qcRpJSEQZetk84w3QUy/zOssRw0IxY9DWFfxbYG+t4BV0v6z6ckahUSv4F7KLhdXA62ruAD5uANOua4iOrxfv+sN4k2K6HuZHKoHXC0MeMG1dz4dZYKemCLmYhOmWLIgoqyM4QV5UAtqBX8Bjs+OtsX3azDLyyJX1grC+xqimlmNmP/XJQsHUBZzF2R97gEUDPPLM9WSdcjO+IWCrvJYA/0zz9j6gxy6+wUYqkiYt0gjYAfRrFZMDjjSakTXBdO0NhDKL7cCBBsu5Zlqvstup24znpqR22VIsaCHgHQp8cwqVfzOtTYEvmYtRCwBfVuDLLQJYMc4r8K/A9xZgXLEV9DRaFIWpVeydangl4LWnCZZ77ANM21PykbAfeBwmAfATmHazw4UWyA4f2Dw3BD4DD03i7usBdDOu3jzleQU0J9lhrNj+1LNi2Vb6lxyV7T/WB40Y6RPbM8A2U1DEbjc3PNRVhquJQqpktQMfPFKyrtei3CrrxyT52mjt8BnQVilEKqlawx6otd31lpR5IzUvbYA+/iqJPu6CP+6ot1l1JPT7PSknG2pm6cA9wO2MekAajn+AyyaWwzS7bqMSe3ENqEa6bhPAUbO7BWnmCcpAG3BesrRKh4b2OFeqvJ0l4I6oaJn0Oaly4wHgKvDEZJfVfA64D1wADiftLKfZywfYDRzkXy+/E9gk1xeAb7LAZ0XnbnovP+4N5OskIZQxiRffX7IVeHSiBHxsAAAAAElFTkSuQmCC", CGRect(x: 174.644, y: 11.582, width: 15.356, height: 15.747))
        }
    }

    var frame: CGRect { source.frame }

    var image: NSImage {
        if let cached = Self.cache[self] { return cached }
        let image = NSImage(size: frame.size)
        if let data = Data(base64Encoded: source.base64), let rep = NSBitmapImageRep(data: data) {
            rep.size = frame.size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }

    private static var cache: [WordmarkPiece: NSImage] = [:]
}

/// The wordmark that forms itself, with the dot behaving like a small HEAVY ball on a hard surface (owner's storyboard):
/// 1. "u u e": the q is turned so its notch faces up; the dot is above it.
/// 2. The dot falls under gravity (fastest at impact, no easing) and hits the notch: 2-frame squash, and in that same
///    frame the letter starts turning from the jolt.
/// 3. The dot rolls straight to the notch's right edge (accelerating, ~70 ms).
/// 4. Its weight tumbles the letter: the turn ACCELERATES the whole way (a body falling over), no ease-out.
/// 5. As the notch's mouth comes round under it, the dot drops out to its place and rides the letter from there.
/// 6. The letter hits its resting position hard, knocks back once or twice (rigid, small) and stops dead: the logo.
/// The motion is simulated once (a small fixed-step physics table) and shown at 24 fps (stepped, like film), so hits
/// read as instant. Reduce Motion (or `animate` false) shows the finished logo. `onFormed` fires when it's complete.
/// (History: v1 eased + bounced, v2 eased roll on contact, v3 eased "physics" timeline — owner: too soft. This is v4.)
struct AnimatedWordmark: View {
    let animate: Bool
    var onFormed: () -> Void = {}
    /// For checking frames: render the pose at this time instead of animating.
    var previewTime: Double? = nil

    @State private var start: Date?
    /// How far above its landing spot the dot starts: just above the window's top edge (measured), so it falls in from outside.
    @State private var dropHeight: CGFloat?
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shown frame rate (stepped). nil = every display frame.
    static let frameRate: Double? = 24

    init(animate: Bool, previewTime: Double? = nil, onFormed: @escaping () -> Void = {}) {
        self.animate = animate
        self.previewTime = previewTime
        self.onFormed = onFormed
    }

    var body: some View {
        Group {
            if let t = previewTime {
                frame(Self.pose(at: t))
            } else if !animate || reduceMotion || finished {
                frame(Self.pose(at: .infinity))
            } else {
                TimelineView(.animation(minimumInterval: Self.frameRate.map { 1 / $0 })) { context in
                    let t = start.map { context.date.timeIntervalSince($0) } ?? 0
                    // Until the window position is measured, the dot waits far above (out of sight).
                    frame(Self.pose(at: Self.frameRate.map { (t * $0).rounded(.down) / $0 } ?? t,
                                    dropHeight: dropHeight ?? 10_000))
                }
            }
        }
        .frame(width: WordmarkPiece.size.width, height: WordmarkPiece.size.height, alignment: .topLeading)
        .background(GeometryReader { proxy in
            // The window's content runs under its transparent title bar, so .global y 0 = the window's top edge.
            Color.clear.onAppear {
                let dotRadius = WordmarkPiece.qDot.frame.height / 2
                dropHeight = max(Self.minDropHeight, proxy.frame(in: .global).minY + Self.landing.y + dotRadius + 2)
            }
        })
        .accessibilityElement()
        .accessibilityLabel("Que")
        .onAppear(perform: run)
    }

    private func run() {
        guard previewTime == nil else { return }
        guard animate, !reduceMotion else { onFormed(); return }
        start = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.endTime) { finished = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.endTime + 0.05) { onFormed() }
    }

    private func frame(_ pose: Pose) -> some View {
        let d = WordmarkPiece.qDot.frame
        return ZStack(alignment: .topLeading) {
            piece(.qBody)
                .frame(width: WordmarkPiece.size.width, height: WordmarkPiece.size.height, alignment: .topLeading)
                .rotationEffect(.degrees(pose.angle), anchor: UnitPoint(x: WordmarkPiece.pivot.x / WordmarkPiece.size.width,
                                                                        y: WordmarkPiece.pivot.y / WordmarkPiece.size.height))
            piece(.u)
            piece(.eBody)
            piece(.eDot)
            Image(nsImage: WordmarkPiece.qDot.image)
                .renderingMode(.template)
                .resizable()
                .frame(width: d.width, height: d.height)
                .scaleEffect(x: pose.squash.width, y: pose.squash.height, anchor: .bottom)
                .offset(x: pose.dot.x - d.width / 2, y: pose.dot.y - d.height / 2)
        }
    }

    private func piece(_ piece: WordmarkPiece) -> some View {
        Image(nsImage: piece.image)
            .renderingMode(.template)
            .resizable()
            .frame(width: piece.frame.width, height: piece.frame.height)
            .offset(x: piece.frame.minX, y: piece.frame.minY)
    }

    // MARK: - Physics

    struct Pose {
        var angle: Double                       // the q's rotation, degrees, clockwise (0 = the logo)
        var dot: CGPoint                        // the dot's centre, wordmark points, screen orientation
        var squash = CGSize(width: 1, height: 1)
    }

    // Geometry (points, letter frame), measured from the owner's artwork.
    static let biteCentre = CGPoint(x: 39.622, y: 44.876)   // centre of the circle the notch is cut from
    static let rollRadius: CGFloat = 12.479 - 7.288          // notch radius − dot radius: path of the dot's centre
    static var dotHome: CGPoint { CGPoint(x: WordmarkPiece.qDot.frame.midX, y: WordmarkPiece.qDot.frame.midY) }
    /// Direction (path angle, degrees, + = right of straight down, letter frame) of the notch's mouth: towards the dot's
    /// home. At the start (letter at −145.72°) that points straight up.
    static let mouthAngle = atan2(Double(43.726 - 39.622), Double(50.884 - 44.876)) * 180 / .pi

    // Tuning.
    static let contact = 0.48                        // impact time; the fall before it is pure gravity
    static let impactSpeed = 2 * 86 / 0.26           // pt/s at the hit: same as the approved 86 pt / 0.26 s drop, so the
                                                     // letter's reaction (jolt, tumble) matches the hit it gets
    static let minDropHeight: CGFloat = 86           // used when the logo isn't in a window (previews)
    static let landAngle = -18.0                     // where the dot hits, on the notch path (deg from straight down)
    static let edgeAngle = 40.0, rollTime = 0.07     // it rolls straight to the right edge
    static let jolt = 140.0                          // deg/s the letter gets in the frame of impact
    static let tumble = 2600.0                       // deg/s² × sin(lean): gravity on the off-centre weight
    static let restitution = 0.25, settleAccel = 3200.0   // rigid knock-back at the landing, then dead stop

    /// Fixed-step simulation of the letter's turn after impact (progress in degrees, 0 → rollAngle, plus knock-backs).
    private static let letterTable: [Double] = {
        let dt = 1.0 / 960, target = WordmarkPiece.rollAngle
        var p = 0.0, v = jolt, out: [Double] = [0], landed = false, bounces = 0
        while out.count < 4000 {
            if !landed {
                // Tumbling: the lean grows as it turns (it starts ~20° off balance from the dot's weight).
                v += tumble * sin((p + 20) * .pi / 180) * dt
            } else {
                v += settleAccel * dt               // after the first hit: pressed hard back onto its rest position
            }
            p += v * dt
            if p >= target && v > 0 {               // hits its resting position: small rigid knock-back
                p = target; landed = true; bounces += 1
                v = -v * restitution
                if abs(v) < 60 || bounces > 2 { out.append(target); break }
            }
            out.append(p)
        }
        return out
    }()
    static var endTime: Double { contact + Double(letterTable.count) / 960 + 0.02 }

    static func letterAngle(at t: Double) -> Double {
        guard t > contact else { return -WordmarkPiece.rollAngle }
        let i = min(letterTable.count - 1, Int((t - contact) * 960))
        return -WordmarkPiece.rollAngle + letterTable[i]
    }

    /// Letter frame → screen orientation around the pivot (clockwise degrees, y down).
    static func toScreen(_ p: CGPoint, angle: Double) -> CGPoint {
        let a = angle * .pi / 180, c = WordmarkPiece.pivot
        let x = p.x - c.x, y = p.y - c.y
        return CGPoint(x: c.x + x * cos(a) - y * sin(a), y: c.y + x * sin(a) + y * cos(a))
    }

    /// The dot's centre on the notch path at screen angle `psi` (degrees from straight down, + = right).
    static func onPath(psi: Double, angle: Double) -> CGPoint {
        let centre = toScreen(biteCentre, angle: angle)
        let r = psi * .pi / 180
        return CGPoint(x: centre.x + rollRadius * CGFloat(sin(r)), y: centre.y + rollRadius * CGFloat(cos(r)))
    }

    /// Where the dot hits the notch (wordmark points).
    static var landing: CGPoint { onPath(psi: landAngle, angle: -WordmarkPiece.rollAngle) }

    static func pose(at t: Double, dropHeight: CGFloat = minDropHeight) -> Pose {
        guard t.isFinite, t < endTime else { return Pose(angle: 0, dot: dotHome) }
        let angle = letterAngle(at: t)
        let landing = self.landing

        // Falling in from above the window: pure gravity from rest, speeding up all the way, fastest at impact.
        // Gravity is set so a drop of any height arrives at `impactSpeed`.
        if t < contact {
            let h = Double(dropHeight)
            let g = impactSpeed * impactSpeed / (2 * h), fall = 2 * h / impactSpeed
            let s = max(0, t - (contact - fall))     // time since it let go
            let height = CGFloat(max(0, h - 0.5 * g * s * s))
            return Pose(angle: angle, dot: CGPoint(x: landing.x, y: landing.y - height))
        }
        // Impact squash: 2 frames at 24 fps, 10% wide and short, anchored on the contact point.
        let since = t - contact
        let squash = since < 0.085 ? CGSize(width: 1.1, height: 0.9) : CGSize(width: 1, height: 1)

        // Rolling to the right edge, accelerating (distance ∝ t²).
        let u = min(1, since / rollTime)
        let psi = landAngle + (edgeAngle - landAngle) * u * u
        let inNotch = onPath(psi: psi, angle: angle)

        // Out of the mouth: once the mouth has turned to within reach under the dot, it drops out (gravity, fast) to
        // its place and rides the letter from there.
        let lambda = psi + angle                       // the dot's direction in the letter's own frame
        let gap = abs(lambda - mouthAngle)
        let exit = max(0, min(1, (55 - gap) / 25))     // 0 = inside the notch, 1 = at home
        let home = toScreen(dotHome, angle: angle)
        let k = CGFloat(exit * exit)
        return Pose(angle: angle,
                    dot: CGPoint(x: inNotch.x + (home.x - inNotch.x) * k, y: inNotch.y + (home.y - inNotch.y) * k),
                    squash: squash)
    }
}
