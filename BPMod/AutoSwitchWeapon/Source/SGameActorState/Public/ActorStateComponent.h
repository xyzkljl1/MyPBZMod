#pragma once
#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "GameplayTagContainer.h"
#include "ActorStateComponent.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FActorStateEndEvent, const TArray<FGameplayTag>&, EndStates, const FGameplayTag&, NewState);
UCLASS(BlueprintType)
class SGAMEACTORSTATE_API UActorStateComponent : public UActorComponent
{
    GENERATED_BODY()
public:
    UPROPERTY(BlueprintAssignable) FActorStateEndEvent OnStateEnd;
};
