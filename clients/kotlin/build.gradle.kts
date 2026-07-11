plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.spotless)
    alias(libs.plugins.vanniktech.maven.publish)
}

group = "io.github.valthon"
version = "0.1.0"

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(17)
}

sourceSets {
    create("integrationTest") {
        kotlin.srcDir("src/integrationTest/kotlin")
        resources.srcDir("src/integrationTest/resources")
        compileClasspath += sourceSets.main.get().output
        runtimeClasspath += output + sourceSets.main.get().output
    }
}

configurations.getByName("integrationTestImplementation") {
    extendsFrom(configurations.getByName("testImplementation"))
}
configurations.getByName("integrationTestRuntimeOnly") {
    extendsFrom(configurations.getByName("testRuntimeOnly"))
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.cio)
    implementation(libs.ktor.client.websockets)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.serialization.kotlinx.json)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.ktor.client.mock)
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}

val integrationTest =
    tasks.register<Test>("integrationTest") {
        description = "Runs integration tests (require a live ZigBase server; excluded from `build`)."
        group = "verification"
        testClassesDirs = sourceSets["integrationTest"].output.classesDirs
        classpath = sourceSets["integrationTest"].runtimeClasspath
        useJUnitPlatform()
        shouldRunAfter(tasks.test)
    }

spotless {
    kotlin {
        target("src/**/*.kt")
        ktlint(libs.versions.ktlint.get())
    }
    kotlinGradle {
        target("*.gradle.kts")
        ktlint(libs.versions.ktlint.get())
    }
}

// Maven Central (Central Portal) publishing -- release-lane only. Coordinates
// come from `group`/`version` above plus the project name ("zigbase-client",
// see settings.gradle.kts); a distinct Maven artifactId is set explicitly for
// clarity since it also appears in RELEASING.md/CHANGELOG.md.
mavenPublishing {
    coordinates(group.toString(), "zigbase-client", version.toString())

    pom {
        name.set("zigbase-client")
        description.set(
            "Kotlin client SDK for ZigBase, a single-binary PocketBase-inspired backend " +
                "written in Zig -- a coroutine-friendly client over Ktor and kotlinx.serialization.",
        )
        url.set("https://github.com/valthon/zigbase")
        licenses {
            license {
                name.set("Apache-2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0")
                distribution.set("repo")
            }
        }
        scm {
            url.set("https://github.com/valthon/zigbase")
            connection.set("scm:git:https://github.com/valthon/zigbase.git")
            developerConnection.set("scm:git:ssh://git@github.com/valthon/zigbase.git")
        }
        developers {
            developer {
                id.set("valthon")
                name.set("David J Parrott")
                url.set("https://github.com/valthon")
            }
        }
    }

    // Central Portal is the only host the plugin targets as of 0.3x -- no
    // `SonatypeHost` parameter. `automaticRelease` defaults to false (a
    // deployment lands in Central Portal for manual review/release rather
    // than auto-releasing); see RELEASING.md.
    publishToMavenCentral()
}

// GPG signing must stay release-lane-only: `publishToMavenLocal` (this task's
// own local sanity check) and CI's `spotlessCheck build`/`integrationTest`
// must never require a GPG key on a contributor's machine. `signAllPublications()`
// unconditionally sets `signing.required = true` for a non-SNAPSHOT version
// (this project always is one) and wires signature artifacts into every
// publication -- including `publishToMavenLocal` -- so it is only called when
// the plugin's own in-memory-key input is actually present, exactly mirroring
// the check `signAllPublications()` itself uses internally. The release
// workflow supplies it via `ORG_GRADLE_PROJECT_signingInMemoryKey` (see
// RELEASING.md); Gradle auto-maps that env var to the `signingInMemoryKey`
// project property.
if (providers.gradleProperty("signingInMemoryKey").isPresent) {
    mavenPublishing {
        signAllPublications()
    }
}
