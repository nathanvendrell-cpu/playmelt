import Foundation
import Sparkle

@main enum UpdaterTests {
    static func main() {
        precondition(!UpdaterController.automaticUpdatesAllowed(info:[:],identifier:"com.playmelt"))
        precondition(!UpdaterController.automaticUpdatesAllowed(info:["PlaymeltDevelopmentBuild":false,"PlaymeltAutomaticUpdatesAvailable":false],identifier:"com.playmelt"))
        precondition(!UpdaterController.automaticUpdatesAllowed(info:["PlaymeltAutomaticUpdatesAvailable":"true"],identifier:"com.playmelt"))
        precondition(!UpdaterController.automaticUpdatesAllowed(info:["PlaymeltDevelopmentBuild":true,"PlaymeltAutomaticUpdatesAvailable":true],identifier:"com.playmelt"))
        precondition(!UpdaterController.automaticUpdatesAllowed(info:["PlaymeltAutomaticUpdatesAvailable":true],identifier:"com.playmelt.preview"))
        precondition(UpdaterController.automaticUpdatesAllowed(info:["PlaymeltDevelopmentBuild":false,"PlaymeltAutomaticUpdatesAvailable":true],identifier:"com.playmelt"))
        let controller=UpdaterController()
        let host=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
        let updater=host.updater
        let item=SUAppcastItem(dictionary:["title":"Fixture 2.2.0","enclosure":["url":"https://example.invalid/Playmelt.zip","sparkle:version":"4","length":"1","type":"application/octet-stream"]])!
        var busy=true,resumes=0,immediate=0
        controller.isBusy={busy}
        precondition(controller.updater(updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{resumes+=1}))
        controller.resumeWhenIdle();precondition(resumes==0)
        precondition(!controller.updaterShouldRelaunchApplication(updater))
        busy=false;controller.resumeWhenIdle();controller.resumeWhenIdle();precondition(resumes==1)
        precondition(controller.updaterShouldRelaunchApplication(updater))
        precondition(!controller.updater(updater,willInstallUpdateOnQuit:item,immediateInstallationBlock:{immediate+=1}))
        precondition(immediate==0)
        busy=true
        precondition(controller.updater(updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{resumes+=1}))
        controller.updater(updater,didAbortWithError:NSError(domain:"fixture",code:1));busy=false;controller.resumeWhenIdle();precondition(resumes==1)
        print("Updater distribution policy, active-work deferral, abort and non-stalling install-on-quit checks passed; updater never started")
    }
}
