# dnsjava includes optional resolver providers for desktop JVM platforms. They
# are unreachable on Android; suppress only those missing optional APIs.
-dontwarn com.sun.jna.**
-dontwarn javax.naming.**
-dontwarn lombok.Generated
-dontwarn org.slf4j.impl.StaticLoggerBinder
-dontwarn sun.net.spi.nameservice.NameServiceDescriptor
