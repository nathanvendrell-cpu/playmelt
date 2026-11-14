import AppKit
import AuthenticationServices

/// The system browser owns Google credentials and cookies, outside our WKWebViews.
final class AccountWebAuthentication:NSObject,ASWebAuthenticationPresentationContextProviding {
    private var session:ASWebAuthenticationSession?
    private var anchor:NSWindow?
    private var identity=UUID()
    func start(url:URL,window:NSWindow?,completion:@escaping(URL?)->Void) {
        guard session==nil,let window else{completion(nil);return}
        anchor=window;let current=UUID();identity=current
        let auth=ASWebAuthenticationSession(url:url,callback:.customScheme("playmelt")) { [weak self] url,error in
            DispatchQueue.main.async {
                guard let self,self.identity==current else{return}
                self.session=nil;self.anchor=nil;completion(error==nil ? url : nil)
            }
        }
        auth.presentationContextProvider=self
        auth.prefersEphemeralWebBrowserSession=false
        session=auth
        if !auth.start(){identity=UUID();session=nil;anchor=nil;completion(nil)}
    }
    func cancel(){identity=UUID();session?.cancel();session=nil;anchor=nil}
    func presentationAnchor(for session:ASWebAuthenticationSession)->ASPresentationAnchor {anchor ?? NSWindow()}
}
