package org.folio.authentication;

import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.authenticators.broker.IdpDetectExistingBrokerUserAuthenticator;
import org.keycloak.authentication.authenticators.broker.util.ExistingUserInfo;
import org.keycloak.authentication.authenticators.broker.util.SerializedBrokeredIdentityContext;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.models.UserModel;

import java.util.Optional;

public class IdpDetectExistingFolioBrokerUserAuthenticator extends IdpDetectExistingBrokerUserAuthenticator {

    @Override
    protected ExistingUserInfo checkExistingUser(AuthenticationFlowContext context, String username, SerializedBrokeredIdentityContext serializedCtx, BrokeredIdentityContext brokerContext) {
        Optional<UserModel> existingUser;
        if (brokerContext.getEmail() != null && !context.getRealm().isDuplicateEmailsAllowed()) {
            existingUser = context.getSession().users().searchForUserByUserAttributeStream(context.getRealm(), "externalId", brokerContext.getEmail()).findFirst();
            if (existingUser.isPresent()) {
                return new ExistingUserInfo(existingUser.get().getId(), UserModel.EMAIL, existingUser.get().getEmail());
            }
        }

        existingUser = context.getSession().users().searchForUserByUserAttributeStream(context.getRealm(), "externalId", username).findFirst();
        return existingUser.map(userModel -> new ExistingUserInfo(userModel.getId(), UserModel.USERNAME, userModel.getUsername())).orElse(null);
    }


}
