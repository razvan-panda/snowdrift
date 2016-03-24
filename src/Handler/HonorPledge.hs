module Handler.HonorPledge where

import Import

import Handler.TH
import Model.User (establishUserDB, curUserIsEligibleEstablish)

getHonorPledgeR :: Handler Html
getHonorPledgeR = do
    is_elig <- curUserIsEligibleEstablish
    muser <- maybeAuth
    $(widget "page/honor-pledge" "Honor Pledge")

postHonorPledgeR :: Handler Html
postHonorPledgeR = do
    Entity user_id user <- requireAuth
    case userEstablished user of
        EstEligible elig_time reason -> do
            runDB $ establishUserDB user_id elig_time reason
            setMessage "Congratulations, you are now a fully established user!"
            redirect HomeR
        EstEstablished{} -> error "You're already an established user."
        _ -> error "You're not eligible for establishment."
