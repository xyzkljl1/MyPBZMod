#pragma once
#include "Commandlets/Commandlet.h"
#include "MCUControlEventsBuildCommandlet.generated.h"

UCLASS()
class UMCUControlEventsBuildCommandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    virtual int32 Main(const FString& Params) override;
};
