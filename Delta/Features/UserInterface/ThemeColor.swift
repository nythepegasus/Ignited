//
//  ThemeColor.swift
//  Delta
//
//  Created by Chris Rittenhouse on 5/2/23.
//  Copyright © 2023 LitRitt. All rights reserved.
//

import SwiftUI

import Features

enum ThemeColor: String, CaseIterable, CustomStringConvertible, Identifiable
{
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case mint = "Mint"
    case teal = "Teal"
    case blue = "Blue"
    case purple = "Purple"
    
    var description: String {
        return self.rawValue
    }
    
    var id: String {
        return self.rawValue
    }
    
    var assetName: String {
        switch self
        {
        case .pink: return "IconPink"
        case .red: return "IconRed"
        case .orange: return "AppIcon"
        case .yellow: return "IconYellow"
        case .green: return "IconGreen"
        case .mint: return "IconMint"
        case .teal: return "IconTeal"
        case .blue: return "IconBlue"
        case .purple: return "IconPurple"
        }
    }
    
    var color: Color {
        switch self
        {
        case .pink: return Color(fromRGB: UIColor.systemPink.cgColor.rgb())
        case .red: return Color(fromRGB: UIColor.systemRed.cgColor.rgb())
        case .orange: return Color(fromRGB: UIColor.ignitedOrange.cgColor.rgb())
        case .yellow: return Color(fromRGB: UIColor.systemYellow.cgColor.rgb())
        case .green: return Color(fromRGB: UIColor.systemGreen.cgColor.rgb())
        case .mint: return Color(fromRGB: UIColor.ignitedMint.cgColor.rgb())
        case .teal: return Color(fromRGB: UIColor.systemTeal.cgColor.rgb())
        case .blue: return Color(fromRGB: UIColor.systemBlue.cgColor.rgb())
        case .purple: return Color(fromRGB: UIColor.deltaPurple.cgColor.rgb())
        }
    }
}

extension ThemeColor: LocalizedOptionValue
{
    var localizedDescription: Text {
        Text(self.description)
    }
}

extension ThemeColor: Equatable
{
    static func == (lhs: ThemeColor, rhs: ThemeColor) -> Bool
    {
        return lhs.description == rhs.description
    }
}

extension Color: LocalizedOptionValue
{
    public var localizedDescription: Text {
        Text(self.description)
    }
}

struct ThemeColorOptions
{
    @Option(name: "Preset Color",
            description: "Choose a theme color from a preset list. Preset colors include a matching app icon.",
            detailView: { value in
        List {
            ForEach(ThemeColor.allCases) { color in
                HStack {
                    if color == value.wrappedValue
                    {
                        Text("✓").foregroundColor(color.color)
                    }
                    color.localizedDescription.foregroundColor(color.color)
                    Spacer()
                    Image(uiImage: Bundle.appIcon(for: color) ?? UIImage())
                        .cornerRadius(13)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    value.wrappedValue = color
                }
            }
        }
        .onChange(of: value.wrappedValue) { _ in
            AppIconOptions.updateAppIcon()
        }
        .displayInline()
    })
    var accentColor: ThemeColor = .orange
    
    @Option(name: "Use Custom Color",
            description: "Use the custom color selected below instead of the preset color above.")
    var useCustom: Bool = false
    
    @Option(name: "Custom Color",
            description: "Select a custom color to use as the theme color.",
            detailView: { value in
        ColorPicker("Custom Color", selection: value, supportsOpacity: false)
            .displayInline()
    })
    var customColor: Color = Color(red: 253/255, green: 110/255, blue: 0/255)
    
    @Option(name: "Restore Defaults",
            description: "Reset all options to their default values.",
            detailView: { _ in
        Button("Restore Defaults") {
            PowerUserOptions.resetFeature(.themeColor)
        }
        .font(.system(size: 17, weight: .bold, design: .default))
        .foregroundColor(.red)
        .displayInline()
    })
    var resetThemeColor: Bool = false
}
