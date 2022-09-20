//  KeePassium Password Manager
//  Copyright © 2018–2022 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import UIKit
import KeePassiumLib

fileprivate let singlelineFields: [String] =
    [EntryField.title, EntryField.userName, EntryField.password, EntryField.url]

protocol ViewableField: AnyObject {
    var field: EntryField? { get set }

    var internalName: String { get }
    var visibleName: String { get }
    
    var value: String? { get }
    var resolvedValue: String? { get }
    var decoratedValue: String? { get }
    
    var isProtected: Bool { get }
    
    var isEditable: Bool { get }

    var isMultiline: Bool { get }

    var isFixed: Bool { get }
    
    var isValueHidden: Bool { get set }

    var isHeightConstrained: Bool { get set }
}

extension ViewableField {
    var isMultiline: Bool {
        return !singlelineFields.contains(internalName)
    }
    
}

class BasicViewableField: ViewableField {
    weak var field: EntryField?
    
    var internalName: String { return field?.name ?? "" }
    var value: String? { return field?.value }
    var resolvedValue: String? { return field?.resolvedValue }
    var decoratedValue: String? { return field?.premiumDecoratedValue }
    var isProtected: Bool { return field?.isProtected ?? false }
    var isFixed: Bool { return field?.isStandardField ?? false }

    var isValueHidden: Bool
    
    var isHeightConstrained: Bool
    
    var isEditable: Bool { return true }
    
    var visibleName: String {
        switch internalName {
        case EntryField.title: return LString.fieldTitle
        case EntryField.userName: return LString.fieldUserName
        case EntryField.password: return LString.fieldPassword
        case EntryField.url: return LString.fieldURL
        case EntryField.notes: return LString.fieldNotes
        default:
            return internalName
        }
    }
    
    convenience init(field: EntryField, isValueHidden: Bool) {
        self.init(fieldOrNil: field, isValueHidden: isValueHidden)
    }
    
    init(fieldOrNil field: EntryField?, isValueHidden: Bool) {
        self.field = field
        self.isValueHidden = isValueHidden
        self.isHeightConstrained = true
    }
}

class DynamicViewableField: BasicViewableField, Refreshable {

    internal var fields: [Weak<EntryField>]

    init(field: EntryField?, fields: [EntryField], isValueHidden: Bool) {
        self.fields = Weak.wrapped(fields)
        super.init(fieldOrNil: field, isValueHidden: isValueHidden)
    }
    
    public func refresh() {
    }
}

class TOTPViewableField: DynamicViewableField {
    var totpGenerator: TOTPGenerator?
    
    override var internalName: String { return EntryField.totp }
    override var visibleName: String { return LString.fieldOTP }

    override var isEditable: Bool { return false }
    
    override var value: String {
        return totpGenerator?.generate() ?? ""
    }
    override var resolvedValue: String? {
        return value
    }
    override var decoratedValue: String? {
        return value
    }
    
    var elapsedTimeFraction: Double? {
        return totpGenerator?.elapsedTimeFraction
    }
    
    init(fields: [EntryField]) {
        super.init(field: nil, fields: fields, isValueHidden: false)
        refresh()
    }
    
    override func refresh() {
        let _fields = Weak.unwrapped(self.fields)
        self.totpGenerator = TOTPGeneratorFactory.makeGenerator(from: _fields) 
    }
}

class ViewableEntryFieldFactory {
    enum ExcludedFields {
        case title
        case emptyValues
        case nonEditable
        case otpConfig
    }
    
    static func makeAll(
        from entry: Entry,
        in database: Database,
        excluding excludedFields: [ExcludedFields]
    ) -> [ViewableField] {
        var result = [ViewableField]()

        let hasValidOTPConfig = TOTPGeneratorFactory.makeGenerator(for: entry) != nil

        var excludedFieldNames = Set<String>()
        if excludedFields.contains(.title) {
            excludedFieldNames.insert(EntryField.title)
        }
        if hasValidOTPConfig && excludedFields.contains(.otpConfig) {
            excludedFieldNames.insert(EntryField.otpConfig1)
            excludedFieldNames.insert(EntryField.otpConfig2Seed)
            excludedFieldNames.insert(EntryField.otpConfig2Settings)
        }
        let excludeEmptyValues = excludedFields.contains(.emptyValues)
        let excludeNonEditable = excludedFields.contains(.nonEditable)
        for field in entry.fields {
            if excludedFieldNames.contains(field.name) {
                continue
            }
            if excludeEmptyValues && field.value.isEmpty {
                continue
            }
            
            let viewableField = makeOne(field: field)
            result.append(viewableField)
        }
        
        if hasValidOTPConfig && !excludeNonEditable {
            result.append(TOTPViewableField(fields: entry.fields))
        }
        
        return result
    }
    
    static private func makeOne(field: EntryField) -> ViewableField {
        let isHidden =
            (field.isProtected || field.name == EntryField.password)
            && Settings.current.isHideProtectedFields
        let result = BasicViewableField(field: field, isValueHidden: isHidden)
        
        if field.name == EntryField.notes {
            result.isHeightConstrained = Settings.current.isCollapseNotesField
        }
        return result
    }
}

