FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY CodexMicro.Relay.csproj ./
RUN dotnet restore CodexMicro.Relay.csproj
COPY Program.cs ./
RUN dotnet publish CodexMicro.Relay.csproj -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish ./
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "CodexMicro.Relay.dll"]
