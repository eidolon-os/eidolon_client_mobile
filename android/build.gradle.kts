allprojects {
    repositories {
        google()
        mavenCentral()
        // Espressif publishes its provisioning client here and nowhere else.
        // The protocol it speaks — protocomm with SRP6a Security2 — is not
        // something to reimplement by reading a spec: it is the vendor's own
        // client for the vendor's own firmware.
        maven { url = uri("https://jitpack.io") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
